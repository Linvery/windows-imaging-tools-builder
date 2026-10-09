[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\Project.Common.ps1')
Assert-PowerShell51
$fixture=Join-Path $root ('local\guest software tests '+[guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $fixture -Force|Out-Null
foreach ($file in @('Software.Selection.ps1','Package.Validation.ps1')) {
    Copy-Item -LiteralPath (Join-Path $root ('scripts\'+$file)) -Destination (Join-Path $fixture $file)
}
foreach ($file in @('chrome-enterprise64.msi','VSCodeSetup-x64.exe','virtio-win-guest-tools.exe')) {
    [IO.File]::WriteAllText((Join-Path $fixture $file),'Fixture; never executed.')
}
# Redirect resources and return exit codes to the test caller. All operating-system
# operations below are mocked; this test never installs software or changes services.
$hook=[IO.File]::ReadAllText((Join-Path $root 'hooks\RunBeforeCloudbaseInitInstall.ps1'))
$hook=$hook.Replace("'C:\UnattendResources\CustomResources'",("'"+$fixture+"'"))
$hook=$hook.Replace('exit 1005','return 1005').Replace('exit 0','return 0').Replace('exit 1','return 1')
$guestHook=[scriptblock]::Create($hook)
& {
    $script:guestState=@{}
    $script:installerCalls=New-Object 'System.Collections.Generic.List[string]'
    $script:signatureStatus='Valid'
    $script:installedChrome=Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'
    $script:installedCode=Join-Path $env:ProgramFiles 'Microsoft VS Code\Code.exe'
    function Test-Path {
        param($LiteralPath,$PathType)
        if ($LiteralPath -eq 'C:\UnattendResources\config.ini') { return $true }
        if ($LiteralPath -eq $script:installedChrome) { return [bool]$script:guestState.Chrome }
        if ($LiteralPath -eq $script:installedCode) { return [bool]$script:guestState.VSCode }
        Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath -PathType Leaf
    }
    function Get-Item {
        param($LiteralPath)
        if ($LiteralPath -in @($script:installedChrome,$script:installedCode)) {
            return [PSCustomObject]@{VersionInfo=[PSCustomObject]@{ProductVersion='999.0.0'}}
        }
        Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath
    }
    function Get-ItemProperty {
        param($Path,$ErrorAction)
        if ($script:guestState.VirtIO) { [PSCustomObject]@{DisplayName='Virtio-win-guest-tools';DisplayVersion='999.0.0'} }
    }
    function Get-AuthenticodeSignature {
        param($LiteralPath)
        $publisher='Microsoft Corporation'
        if ([IO.Path]::GetExtension($LiteralPath) -eq '.msi') { $publisher='Google LLC' }
        $certificate=[PSCustomObject]@{Publisher=$publisher}
        $certificate | Add-Member -MemberType ScriptMethod -Name GetNameInfo -Value {param($Type,$ForIssuer) $this.Publisher}
        [PSCustomObject]@{Status=$script:signatureStatus;SignerCertificate=$certificate}
    }
    function Start-Process {
        param($FilePath,$ArgumentList,$WindowStyle,[switch]$PassThru)
        if ($WindowStyle -ne 'Hidden') { throw 'Unexpected visible installer.' }
        $name='Chrome'
        if ($FilePath -like '*VSCodeSetup-*') { $name='VSCode' }
        elseif ($FilePath -like '*virtio-win-guest-tools.exe') { $name='VirtIO' }
        elseif ($FilePath -ne 'msiexec.exe') { throw 'Unexpected process in guest test.' }
        $script:installerCalls.Add($name)
        $script:guestState[$name]=$true
        $exitCode=0
        if ($name -eq 'VirtIO') { $exitCode=3010 }
        $process=[PSCustomObject]@{Handle=[IntPtr]::Zero;ExitCode=$exitCode}
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {}
        return $process
    }
    function Get-Service {
        param($Name,$ErrorAction)
        if ($Name -ne 'qemu-ga') { throw 'Unexpected service query.' }
        if ($script:guestState.VirtIO) { [PSCustomObject]@{Name=$Name} }
    }
    function Set-Service {
        param($Name,$StartupType)
        if ($Name -ne 'qemu-ga' -or $StartupType -ne 'Automatic') { throw 'Unexpected service mutation.' }
    }
    $checked=0
    foreach ($chrome in @($false,$true)) {
        foreach ($code in @($false,$true)) {
            $selection=@{SchemaVersion=1;InstallChrome=$chrome;InstallVSCode=$code}
            [IO.File]::WriteAllText((Join-Path $fixture 'software-selection.json'),($selection|ConvertTo-Json))
            $script:guestState=@{}
            $script:installerCalls.Clear()
            $first=& $guestHook
            if ($first -ne 1005) { throw 'First pass did not request the installer reboot.' }
            $expected=1+[int]$chrome+[int]$code
            if ($script:installerCalls.Count -ne $expected -or
                ($script:installerCalls.Contains('Chrome') -ne $chrome) -or
                ($script:installerCalls.Contains('VSCode') -ne $code)) { throw 'Guest installed an incorrect software selection.' }
            $resumed=& $guestHook
            if ($resumed -ne 0 -or $script:installerCalls.Count -ne $expected) { throw 'Guest reinstalled software or requested another reboot on resume.' }
            $checked++
        }
    }
    $script:guestState=@{}
    $script:installerCalls.Clear()
    $script:signatureStatus='HashMismatch'
    $failed=& $guestHook 2>$null
    if ($failed -ne 1 -or $script:installerCalls.Count) { throw 'Guest did not stop before installing an invalidly signed package.' }
    [PSCustomObject]@{GuestSoftwareCombinations=$checked;RebootResume='passed; no repeat installation';InvalidSignature='stopped before installation';SystemOperations='mocked'}
}
