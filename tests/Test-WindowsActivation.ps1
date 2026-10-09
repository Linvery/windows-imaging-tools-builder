$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'scripts\Project.Common.ps1')
Assert-PowerShell51
function Assert-ActivationTest { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }

$fixture = Join-Path $repo ('local\windows activation tests ' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$scriptPath = Join-Path $fixture '30-WindowsActivation.ps1'
$settingsPath = Join-Path $fixture 'kms-settings.json'
Copy-Item -LiteralPath (Join-Path $repo 'resources\Activate-Windows.ps1') -Destination $scriptPath
$previousProgramData = $env:ProgramData
try {
    $env:ProgramData = Join-Path $fixture 'ProgramData'
    $reportPath = Join-Path $env:ProgramData 'PveImageBuilder\windows-activation.json'
    & {
        function New-TestLicense {
            param([int]$Status=0,[string]$Description='Windows Operating System, VOLUME_KMSCLIENT channel',[bool]$Addon=$false)
            [PSCustomObject]@{ID='00000000-0000-0000-0000-000000000001';Description=$Description;LicenseIsAddon=$Addon;LicenseStatus=$Status;LicenseStatusReason=0;PartialProductKey='ABCDE'}
        }
        function Reset-ActivationTest {
            $global:PveActivationTest = @{
                Products=@(New-TestLicense);CurrentProducts=@(New-TestLicense -Status 1)
                Reads=0;Calls=(New-Object 'System.Collections.Generic.List[object]')
                ReturnMode='Object';ReturnCode=0;MethodFailure=$false;ReadbackFailure=$false
                Host='kms.example.com';Port=1689;DiagnosticFailure=$false
            }
            [IO.File]::WriteAllText($settingsPath,(@{SchemaVersion=1;Host='kms.example.com';Port=1689} | ConvertTo-Json))
        }
        function Get-CimInstance {
            param($ClassName,$Filter,$ErrorAction)
            if ($ClassName -eq 'SoftwareLicensingService') {
                return [PSCustomObject]@{KeyManagementServiceMachine=$global:PveActivationTest.Host;KeyManagementServicePort=$global:PveActivationTest.Port}
            }
            Assert-ActivationTest ($ClassName -eq 'SoftwareLicensingProduct') 'Unexpected licensing query.'
            Assert-ActivationTest ($Filter -eq "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL") 'Activation query did not restrict installed Windows licenses.'
            $global:PveActivationTest.Reads++
            if ($global:PveActivationTest.Reads -eq 1) { return $global:PveActivationTest.Products }
            if ($global:PveActivationTest.ReadbackFailure) { throw 'Mocked license readback failure.' }
            $global:PveActivationTest.CurrentProducts
        }
        function Invoke-CimMethod {
            param($InputObject,$MethodName,$OperationTimeoutSec,$ErrorAction)
            Assert-ActivationTest ($MethodName -eq 'Activate' -and $OperationTimeoutSec -eq 30) 'Activation was not bounded or used an unexpected method.'
            Assert-ActivationTest ($InputObject.Description -match '\bVOLUME_KMSCLIENT\b' -and -not $InputObject.LicenseIsAddon) 'Activation targeted a non-KMS or addon license.'
            $global:PveActivationTest.Calls.Add($InputObject.ID)
            if ($global:PveActivationTest.MethodFailure) { throw 'Mocked unavailable KMS server or network timeout.' }
            switch ($global:PveActivationTest.ReturnMode) {
                'Object' { [PSCustomObject]@{ReturnValue=$global:PveActivationTest.ReturnCode} }
                'Scalar' { [uint32]$global:PveActivationTest.ReturnCode }
                'Missing' { [PSCustomObject]@{} }
                'NullValue' { [PSCustomObject]@{ReturnValue=$null} }
                'Null' { $null }
            }
        }
        function New-Item {
            param($ItemType,$Path,[switch]$Force)
            if ($global:PveActivationTest.DiagnosticFailure) { throw 'Mocked diagnostics write failure.' }
            Microsoft.PowerShell.Management\New-Item -ItemType $ItemType -Path $Path -Force:$Force
        }
        function Invoke-ActivationTest {
            & $scriptPath | Out-Null
            Assert-ActivationTest ($LASTEXITCODE -eq 0) 'Activation failure blocked Cloudbase-Init or requested a reboot.'
            $raw = Get-Content -Raw -LiteralPath $reportPath
            Assert-ActivationTest ($raw -notmatch 'ABCDE' -and $raw -notmatch 'PartialProductKey') 'Activation diagnostics disclosed product key information.'
            $report = $raw | ConvertFrom-Json
            Assert-ActivationTest ($report.CompletedUtc -and $report.StartedUtc -and $report.KmsHost -eq 'kms.example.com' -and $report.KmsPort -eq 1689) 'Activation diagnostics are incomplete.'
            $report
        }

        foreach ($mode in @('Object','Scalar','Missing','NullValue','Null')) {
            Reset-ActivationTest
            $global:PveActivationTest.ReturnMode = $mode
            $report = Invoke-ActivationTest
            Assert-ActivationTest ($report.Outcome -eq 'Activated' -and $report.Attempted -and $report.LicenseStatus -eq 1 -and $global:PveActivationTest.Calls.Count -eq 1) 'A licensed readback was not accepted after activation.'
        }
        Reset-ActivationTest
        $global:PveActivationTest.Products = @(New-TestLicense -Status 1)
        $report = Invoke-ActivationTest
        Assert-ActivationTest ($report.Outcome -eq 'AlreadyActivated' -and -not $report.Attempted -and $global:PveActivationTest.Calls.Count -eq 0) 'An already activated license received another request.'

        foreach ($products in @(@(),@(New-TestLicense -Description 'Windows Operating System, RETAIL channel'),@(New-TestLicense -Addon $true))) {
            Reset-ActivationTest
            $global:PveActivationTest.Products = $products
            $report = Invoke-ActivationTest
            Assert-ActivationTest ($report.Outcome -eq 'Skipped' -and -not $report.Attempted -and $global:PveActivationTest.Calls.Count -eq 0) 'An absent, retail, or addon license was activated.'
        }
        Reset-ActivationTest
        $global:PveActivationTest.Products = @((New-TestLicense),(New-TestLicense))
        $report = Invoke-ActivationTest
        Assert-ActivationTest ($report.Outcome -eq 'Failed' -and -not $report.Attempted -and $global:PveActivationTest.Calls.Count -eq 0) 'Ambiguous KMS licenses were activated.'

        foreach ($mode in @('Object','Scalar')) {
            Reset-ActivationTest
            $global:PveActivationTest.ReturnMode = $mode
            $global:PveActivationTest.ReturnCode = 5
            $report = Invoke-ActivationTest
            Assert-ActivationTest ($report.Outcome -eq 'Failed' -and $report.ReturnValue -eq 5 -and $report.Message -match 'error 5') 'A CIM failure code was reported as successful activation.'
        }
        Reset-ActivationTest
        $global:PveActivationTest.CurrentProducts = @(New-TestLicense -Status 5)
        $global:PveActivationTest.CurrentProducts[0].LicenseStatusReason = 3221549092
        $report = Invoke-ActivationTest
        Assert-ActivationTest ($report.Outcome -eq 'Failed' -and $report.LicenseStatus -eq 5 -and $report.LicenseStatusReason -eq 3221549092) 'An unlicensed readback was reported as activation success.'

        foreach ($failure in @('MethodFailure','ReadbackFailure')) {
            Reset-ActivationTest
            $global:PveActivationTest[$failure] = $true
            $report = Invoke-ActivationTest
            Assert-ActivationTest ($report.Outcome -eq 'Failed' -and $report.Attempted -and $report.Message -match 'Mocked' -and $global:PveActivationTest.Calls.Count -eq 1) 'Licensing/network errors were lost or caused another attempt.'
        }
        foreach ($field in @('Host','Port')) {
            Reset-ActivationTest
            if ($field -eq 'Host') { $global:PveActivationTest.Host = 'stale.example.com' }
            else { $global:PveActivationTest.Port = 1688 }
            $report = Invoke-ActivationTest
            Assert-ActivationTest ($report.Outcome -eq 'Failed' -and -not $report.Attempted -and $global:PveActivationTest.Calls.Count -eq 0) 'A stale KMS endpoint received activation.'
        }
        foreach ($invalid in @('missing','malformed','invalid')) {
            Reset-ActivationTest
            switch ($invalid) {
                'missing' { Remove-Item -LiteralPath $settingsPath }
                'malformed' { [IO.File]::WriteAllText($settingsPath,'{broken') }
                'invalid' { [IO.File]::WriteAllText($settingsPath,(@{SchemaVersion=1;Host='https://invalid';Port=1689} | ConvertTo-Json)) }
            }
            & $scriptPath | Out-Null
            $report = Get-Content -Raw -LiteralPath $reportPath | ConvertFrom-Json
            Assert-ActivationTest ($LASTEXITCODE -eq 0 -and $report.Outcome -eq 'Failed' -and -not $report.Attempted -and $global:PveActivationTest.Calls.Count -eq 0) 'Invalid settings blocked initialization or reached activation.'
        }
        Reset-ActivationTest
        $global:PveActivationTest.MethodFailure = $true
        $global:PveActivationTest.DiagnosticFailure = $true
        & $scriptPath | Out-Null
        Assert-ActivationTest ($LASTEXITCODE -eq 0) 'An unwritable diagnostic directory blocked Cloudbase-Init.'
    }
}
finally {
    $env:ProgramData = $previousProgramData
    Remove-Variable -Name PveActivationTest -Scope Global -ErrorAction SilentlyContinue
}
[PSCustomObject]@{Activation='mocked; host never activated';SuccessfulReadback='passed';NetworkAndLicensingErrors='nonblocking';MissingOrOtherLicense='skipped';RequestTimeoutSeconds=30;RequestsPerRun=1;Diagnostics='passed';CloudbaseExitCode=0}
