$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\Project.Common.ps1')
Assert-PowerShell51
function Assert-BootTest { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }
function Assert-BootPending {
    param([scriptblock]$Action,[string]$ExpectedMessage)
    $message=$null
    try { & $Action|Out-Null } catch { $message=$_.Exception.Message }
    Assert-BootTest ($message -and $message -match $ExpectedMessage) ('Expected boot verification to wait or fail: '+$ExpectedMessage+'; got: '+$message)
}
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Verify-BuiltImage.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors|Out-String) }
$blocks=@($ast.FindAll({param($node)
    $node -is [System.Management.Automation.Language.ScriptBlockAst] -and
    $node.ParamBlock.Parameters.Count -eq 5 -and
    $node.ParamBlock.Parameters[2].Name.VariablePath.UserPath -eq 'VerifyActivation'
},$true))
Assert-BootTest ($blocks.Count -eq 1) 'The guest boot verification probe was not found uniquely.'
$probe=$blocks[0].GetScriptBlock()
$fixture=Join-Path $root ('local\boot verification tests '+[guid]::NewGuid().ToString('N').Substring(0,8))
$priorProgramData=$env:ProgramData
$priorProgramFiles=$env:ProgramFiles
try {
    $env:ProgramData=Join-Path $fixture 'ProgramData'
    $env:ProgramFiles=Join-Path $fixture 'Program Files'
    $activationPath=Join-Path $env:ProgramData 'PveImageBuilder\windows-activation.json'
    $cloudbaseLog=Join-Path $env:ProgramFiles 'Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init.log'
    foreach ($path in @($activationPath,$cloudbaseLog)) { New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force|Out-Null }
    & {
        function Reset-BootTest {
            $global:PveGuestBootTest=@{Host='kms.example.com';Port=1688}
            $report=@{SchemaVersion=1;Outcome='Failed';Attempted=$true;KmsHost='kms.example.com';KmsPort=1688;CompletedUtc=[DateTime]::UtcNow.ToString('o');Message='Mocked unavailable KMS server.'}
            [IO.File]::WriteAllText($activationPath,($report|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($cloudbaseLog,('INFO Script "C:\LocalScripts\30-WindowsActivation.ps1" ended with exit code: 0'+[Environment]::NewLine+'INFO Plugins execution done'))
        }
        function Get-LocalUser {
            param($Name,$ErrorAction)
            if ($Name -eq 'Admin') { return $null }
            [PSCustomObject]@{SID=[PSCustomObject]@{Value='S-1-5-21-1-2-3-500'};Enabled=$true}
        }
        function Get-Service { param($Name) [PSCustomObject]@{Name=$Name;StartType='Automatic'} }
        function Get-ItemProperty { param($LiteralPath,$Name) [PSCustomObject]@{fDenyTSConnections=0;UserAuthentication=1} }
        function Get-NetTCPConnection { param($LocalPort,$State,$ErrorAction) [PSCustomObject]@{LocalPort=3389;State='Listen'} }
        function Get-NetFirewallProfile { [PSCustomObject]@{Enabled='False'} }
        function Get-CimInstance {
            param($ClassName,$Filter,$ErrorAction)
            switch ($ClassName) {
                'Win32_OperatingSystem' { [PSCustomObject]@{Version='10.0.26100'} }
                'SoftwareLicensingService' { [PSCustomObject]@{KeyManagementServiceMachine=$global:PveGuestBootTest.Host;KeyManagementServicePort=$global:PveGuestBootTest.Port} }
                'SoftwareLicensingProduct' { [PSCustomObject]@{Description='Windows Operating System, VOLUME_KMSCLIENT channel';LicenseIsAddon=$false} }
                default { throw ('Unexpected guest CIM query: '+$ClassName) }
            }
        }
        function Invoke-CimMethod { throw 'Boot verification must not issue an activation request.' }
        foreach ($outcome in @('Failed','Skipped','Activated','AlreadyActivated')) {
            Reset-BootTest
            $report=Get-Content -Raw -LiteralPath $activationPath|ConvertFrom-Json
            $report.Outcome=$outcome
            [IO.File]::WriteAllText($activationPath,($report|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
            $proof=& $probe $false $false $true 'kms.example.com' 1688
            Assert-BootTest ($proof.Boot -eq 'passed' -and $proof.CloudbaseLocalScriptsCompleted -and $proof.KmsSettingsReapplied -and $proof.WindowsKmsClientInstalled -and $proof.WindowsActivation.Outcome -eq $outcome) 'Completed initialization incorrectly required activation success.'
        }
        Reset-BootTest
        Remove-Item -LiteralPath $activationPath
        Assert-BootPending { & $probe $false $false $true 'kms.example.com' 1688 } 'Waiting for the optional activation script'
        foreach ($log in @('INFO Executing plugin LocalScriptsPlugin',
            'INFO Script "C:\LocalScripts\30-WindowsActivation.ps1" ended with exit code: 0',
            ('INFO Script "C:\LocalScripts\30-WindowsActivation.ps1" ended with exit code: 1'+[Environment]::NewLine+'INFO Plugins execution done'))) {
            Reset-BootTest
            [IO.File]::WriteAllText($cloudbaseLog,$log)
            Assert-BootPending { & $probe $false $false $true 'kms.example.com' 1688 } 'Waiting for Cloudbase-Init LocalScripts'
        }
        Reset-BootTest
        $global:PveGuestBootTest.Host='stale.example.com'
        Assert-BootPending { & $probe $false $false $true 'kms.example.com' 1688 } 'KMS settings were not reapplied'
        Reset-BootTest
        $report=Get-Content -Raw -LiteralPath $activationPath|ConvertFrom-Json
        $report.CompletedUtc=$null
        [IO.File]::WriteAllText($activationPath,($report|ConvertTo-Json))
        Assert-BootPending { & $probe $false $false $true 'kms.example.com' 1688 } 'diagnostics are incomplete'
        Remove-Item -LiteralPath $activationPath,$cloudbaseLog
        $proof=& $probe $false $false $false '' 1688
        Assert-BootTest ($proof.Boot -eq 'passed') 'Legacy or blank KMS configurations acquired an activation requirement.'
    }
}
finally {
    $env:ProgramData=$priorProgramData
    $env:ProgramFiles=$priorProgramFiles
    Remove-Variable -Name PveGuestBootTest -Scope Global -ErrorAction SilentlyContinue
}
[PSCustomObject]@{EarlyShutdownRegression='passed';ActivationFailure='accepted after initialization completes';IncompleteLocalScripts='wait';KmsReadback='passed';LegacyAndBlank='passed';HostOperations='mocked'}
