function script:Get-PveCloudbaseInitPackage {
    param([ValidateSet('AMD64','x64','i386','x86')][string]$OsArch='AMD64',[switch]$BetaRelease)
    $architecture='x64'
    if ($OsArch -in @('i386','x86')) { $architecture='x86' }
    $suffix='_Stable'
    if ($BetaRelease) { $suffix='' }
    $name='CloudbaseInitSetup'+$suffix+'_'+$architecture+'.msi'
    [PSCustomObject]@{Name=$name;Architecture=$architecture;Url=('https://www.cloudbase.it/downloads/'+$name)}
}

function script:Get-PveCloudbaseInitCachePath {
    param([Parameter(Mandatory=$true)][string]$AssetsRoot,[string]$OsArch='AMD64',[switch]$BetaRelease)
    $package=Get-PveCloudbaseInitPackage -OsArch $OsArch -BetaRelease:$BetaRelease
    [IO.Path]::GetFullPath((Join-Path $AssetsRoot ('assets\'+$package.Name)))
}

function script:Assert-PveCloudbaseInitInstaller {
    param([Parameter(Mandatory=$true)][string]$Path,[string]$OsArch='AMD64')
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw ('Cloudbase-Init installer is missing: '+$Path) }
    $installer=$null;$database=$null;$view=$null;$record=$null;$summary=$null
    try {
        $installer=New-Object -ComObject WindowsInstaller.Installer
        # Open the MSI read-only; this does not install software on the build host.
        $database=$installer.GetType().InvokeMember('OpenDatabase','InvokeMethod',$null,$installer,@([IO.Path]::GetFullPath($Path),0))
        $view=$database.GetType().InvokeMember('OpenView','InvokeMethod',$null,$database,@('SELECT `Value` FROM `Property` WHERE `Property` = ''ProductName'''))
        $view.GetType().InvokeMember('Execute','InvokeMethod',$null,$view,$null) | Out-Null
        $record=$view.GetType().InvokeMember('Fetch','InvokeMethod',$null,$view,$null)
        if (-not $record) { throw 'MSI ProductName is missing.' }
        $product=$record.GetType().InvokeMember('StringData','GetProperty',$null,$record,@(1))
        if ($product -notmatch '^Cloudbase-Init(?: \d[\w.+-]*)?$') { throw ('Unexpected MSI product: '+$product) }
        $summary=$database.GetType().InvokeMember('SummaryInformation','GetProperty',$null,$database,@(0))
        $platform=($summary.GetType().InvokeMember('Property','GetProperty',$null,$summary,@(7)) -split ';')[0]
        $expected='x64'
        if ((Get-PveCloudbaseInitPackage -OsArch $OsArch).Architecture -eq 'x86') { $expected='Intel' }
        if ($platform -ine $expected) { throw ('Incorrect MSI architecture: '+$platform+'; expected '+$expected) }
    } catch { throw ('Cloudbase-Init installer is not a valid matching MSI: '+$Path+'. '+$_.Exception.Message) }
    finally {
        foreach ($comObject in @($summary,$record,$view,$database,$installer)) {
            if ($null -ne $comObject) { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($comObject) | Out-Null }
        }
    }
}

function script:Invoke-PveCloudbaseInitDownload {
    param([string]$Uri,[string]$Destination)
    $previousProtocol=[Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol=$previousProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
    } finally { [Net.ServicePointManager]::SecurityProtocol=$previousProtocol }
}

function script:Initialize-PveCloudbaseInitInstaller {
    param([Parameter(Mandatory=$true)][string]$AssetsRoot,[string]$OsArch='AMD64',[switch]$BetaRelease)
    $package=Get-PveCloudbaseInitPackage -OsArch $OsArch -BetaRelease:$BetaRelease
    $destination=Get-PveCloudbaseInitCachePath -AssetsRoot $AssetsRoot -OsArch $OsArch -BetaRelease:$BetaRelease
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        try {
            Assert-PveCloudbaseInitInstaller -Path $destination -OsArch $OsArch
            Write-Host ('复用 Cloudbase-Init 安装包：'+$destination)
            return $destination
        } catch { Write-Host ('Cloudbase-Init 缓存无效，重新下载：'+$destination) -ForegroundColor Yellow }
    }
    $directory=Split-Path -Parent $destination
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporary=Join-Path $directory ($package.Name+'.'+[guid]::NewGuid().ToString('N')+'.partial.msi')
    try {
        Write-Host ('下载 Cloudbase-Init：'+$package.Url)
        Invoke-PveCloudbaseInitDownload -Uri $package.Url -Destination $temporary
        Assert-PveCloudbaseInitInstaller -Path $temporary -OsArch $OsArch
        if (Test-Path -LiteralPath $destination -PathType Leaf) { [IO.File]::Replace($temporary,$destination,[System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temporary,$destination) }
        return $destination
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
}
