function Get-GuestSoftwareSelection {
    param([string]$ResourceRoot)
    $path = Join-Path $ResourceRoot 'software-selection.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [PSCustomObject]@{InstallChrome=$true;InstallVSCode=$true}
    }
    $selection = Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json
    if ($selection.SchemaVersion -ne 1 -or $selection.InstallChrome -isnot [bool] -or $selection.InstallVSCode -isnot [bool]) { throw 'Invalid guest software selection.' }
    if ($selection.PSObject.Properties['ProductKeyMode'] -and $selection.ProductKeyMode -notin @('Legacy','Kms','Custom','None')) { throw 'Invalid product key selection mode.' }
    if ($selection.PSObject.Properties['KmsServer']) {
        if ($selection.KmsServer -isnot [string]) { throw 'Invalid KMS server selection.' }
        $selection.KmsServer=(ConvertTo-PveKmsEndpoint -Address $selection.KmsServer).Address
    }
    return $selection
}
function Get-PveDefaultKmsServer { return 'kms-default.cangshui.net' }
function ConvertTo-PveKmsEndpoint {
    param([AllowEmptyString()][string]$Address)
    $address=([string]$Address).Trim()
    if (-not $address) { return [PSCustomObject]@{Address='';Host='';Port=1688} }
    $hostName=$address
    $port=1688
    $portText=$null
    if ($address -match '^\[([^\[\]]+)\](?::([0-9]+))?$') {
        $hostName=$Matches[1]
        if ($Matches[2]) { $portText=$Matches[2] }
        if ([Uri]::CheckHostName($hostName) -ne [UriHostNameType]::IPv6) { throw 'KMS brackets require an IPv6 address.' }
    } elseif ($address -match '^([^:]+):([0-9]+)$') {
        $hostName=$Matches[1]
        $portText=$Matches[2]
    }
    if ($hostName -match '[\s/\\"'';]' -or [Uri]::CheckHostName($hostName) -eq [UriHostNameType]::Unknown) { throw 'KMS address must be a hostname or IP address, optionally followed by a port.' }
    if ($null -ne $portText -and (-not [int]::TryParse($portText,[ref]$port) -or $port -lt 1 -or $port -gt 65535)) { throw 'KMS port must be between 1 and 65535.' }
    return [PSCustomObject]@{Address=$address;Host=$hostName;Port=$port}
}
