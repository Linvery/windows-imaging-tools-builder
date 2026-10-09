$ErrorActionPreference = 'Stop'

# Staged for Cloudbase-Init LocalScripts only; the build hook never invokes it.
$report = [ordered]@{
    SchemaVersion = 1
    StartedUtc = [DateTime]::UtcNow.ToString('o')
    Outcome = 'Skipped'
    Attempted = $false
    KmsHost = $null
    KmsPort = $null
    ProductId = $null
    LicenseStatus = $null
    LicenseStatusReason = $null
    ReturnValue = $null
    Message = $null
}

try {
    $settingsPath = Join-Path $PSScriptRoot 'kms-settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) { throw 'Guest KMS settings are missing.' }
    $settings = Get-Content -Raw -Encoding UTF8 -LiteralPath $settingsPath | ConvertFrom-Json
    if ($settings.SchemaVersion -ne 1 -or $settings.Host -isnot [string] -or
        [Uri]::CheckHostName($settings.Host) -eq [UriHostNameType]::Unknown -or
        $settings.Port -isnot [int] -or $settings.Port -lt 1 -or $settings.Port -gt 65535) { throw 'Invalid guest KMS settings.' }
    $report.KmsHost = $settings.Host
    $report.KmsPort = $settings.Port

    # 20-KmsSettings.ps1 runs first. Do not activate against stale settings if it failed.
    $service = Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop
    if ($service.KeyManagementServiceMachine -ine $settings.Host -or
        $service.KeyManagementServicePort -ne $settings.Port) { throw 'The selected KMS server has not been applied; activation was not requested.' }

    $filter = "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL"
    $products = @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter $filter -ErrorAction Stop |
        Where-Object { $_.Description -match '\bVOLUME_KMSCLIENT\b' -and -not $_.LicenseIsAddon })
    if ($products.Count -eq 0) {
        $report.Message = 'No installed Windows KMS client license was found; activation was not requested.'
    }
    else {
        if ($products.Count -ne 1) { throw 'Multiple Windows KMS client licenses were found; activation was not requested.' }
        $product = $products[0]
        $report.ProductId = $product.ID
        $report.LicenseStatus = $product.LicenseStatus
        $report.LicenseStatusReason = $product.LicenseStatusReason
        if ($product.LicenseStatus -eq 1) {
            $report.Outcome = 'AlreadyActivated'
            $report.Message = 'Windows is already activated.'
        }
        else {
            $report.Attempted = $true
            # Equivalent to slmgr /ato for this Windows KMS license, with a bounded CIM request.
            $result = Invoke-CimMethod -InputObject $product -MethodName Activate -OperationTimeoutSec 30 -ErrorAction Stop
            if ($result -is [int] -or $result -is [uint32]) { $report.ReturnValue = $result }
            elseif ($null -ne $result -and $result.PSObject.Properties['ReturnValue']) { $report.ReturnValue = $result.ReturnValue }

            $current = @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter $filter -ErrorAction Stop |
                Where-Object { $_.ID -eq $product.ID })
            if ($current.Count -ne 1) { throw 'The Windows license could not be read back after the activation request.' }
            $report.LicenseStatus = $current[0].LicenseStatus
            $report.LicenseStatusReason = $current[0].LicenseStatusReason
            if ($null -ne $report.ReturnValue -and $report.ReturnValue -ne 0) { throw ('Windows activation returned error ' + $report.ReturnValue + '.') }
            if ($report.LicenseStatus -ne 1) { throw ('Windows is not activated after the request (LicenseStatus=' + $report.LicenseStatus + ', LicenseStatusReason=' + $report.LicenseStatusReason + ').') }
            $report.Outcome = 'Activated'
            $report.Message = 'Windows activation was confirmed by the licensing service.'
        }
    }
}
catch {
    $report.Outcome = 'Failed'
    $report.Message = $_.Exception.Message
    $report.ExceptionHResult = $_.Exception.HResult
}

$report.CompletedUtc = [DateTime]::UtcNow.ToString('o')
try {
    $diagnosticDirectory = Join-Path $env:ProgramData 'PveImageBuilder'
    New-Item -ItemType Directory -Path $diagnosticDirectory -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $diagnosticDirectory 'windows-activation.json'),
        ($report | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
}
catch { Write-Warning ('Could not save Windows activation diagnostics: ' + $_.Exception.Message) -WarningAction Continue }

if ($report.Outcome -eq 'Failed') { Write-Warning ('Windows activation is optional; initialization will continue. ' + $report.Message) -WarningAction Continue }
else { Write-Host $report.Message }
# Cloudbase-Init must finish even when the deployment has no network or KMS access.
exit 0
