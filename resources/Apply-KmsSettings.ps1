$ErrorActionPreference='Stop'
$settingsPath=Join-Path $PSScriptRoot 'kms-settings.json'
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) { throw 'Guest KMS settings are missing.' }
$settings=Get-Content -Raw -Encoding UTF8 -LiteralPath $settingsPath | ConvertFrom-Json
if ($settings.SchemaVersion -ne 1 -or $settings.Host -isnot [string] -or
    [Uri]::CheckHostName($settings.Host) -eq [UriHostNameType]::Unknown -or
    $settings.Port -isnot [int] -or $settings.Port -lt 1 -or $settings.Port -gt 65535) { throw 'Invalid guest KMS settings.' }
# Configure the Windows licensing service locally. No activation request is sent.
$service=Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop
foreach ($operation in @(
    @{Name='SetKeyManagementServiceMachine';Arguments=@{MachineName=$settings.Host}},
    @{Name='SetKeyManagementServicePort';Arguments=@{PortNumber=[uint32]$settings.Port}}
)) {
    $result=Invoke-CimMethod -InputObject $service -MethodName $operation.Name -Arguments $operation.Arguments -ErrorAction Stop
    # Some Windows licensing providers complete the CIM method without a numeric
    # return value. A missing return value is not a failure code; verify the settings below.
    $returnValue=$null
    if ($result -is [int] -or $result -is [uint32]) { $returnValue=$result }
    elseif ($null -ne $result) {
        $returnProperty=$result.PSObject.Properties['ReturnValue']
        if ($returnProperty) { $returnValue=$returnProperty.Value }
    }
    if ($null -ne $returnValue -and $returnValue -ne 0) { throw ('Could not configure the KMS server: '+$operation.Name+' returned '+$returnValue) }
}
$configured=Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop
if ($configured.KeyManagementServiceMachine -ine $settings.Host -or
    $configured.KeyManagementServicePort -ne $settings.Port) { throw 'The KMS server configuration did not persist in the Windows licensing service.' }
Write-Host ('KMS server configured: '+$settings.Host+':'+$settings.Port)
