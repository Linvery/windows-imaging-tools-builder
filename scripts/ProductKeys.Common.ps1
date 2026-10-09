function script:Get-PveKmsCatalog {
    Import-PowerShellDataFile -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\Kms.ClientKeys.psd1')
}
function script:Get-PveKmsProductKey {
    param([string]$ImageName)
    $name=([regex]::Replace($ImageName,'\s+',' ')).Trim()
    foreach ($entry in (Get-PveKmsCatalog).Entries) {
        if ($name -in $entry.Names) { return [string]$entry.Key }
    }
}
function script:Assert-PveProductKey {
    param([AllowEmptyString()][string]$ProductKey)
    if ($ProductKey -and $ProductKey -notmatch '^[A-Z0-9]{5}(?:-[A-Z0-9]{5}){4}$') { throw 'Product key must contain five groups of five letters or digits.' }
}
function script:Resolve-PveProductKey {
    param([string]$ImageName,[ValidateSet('Legacy','Kms','Custom','None')][string]$Mode='Legacy',[AllowEmptyString()][string]$ProductKey='')
    $key=([string]$ProductKey).Trim().ToUpperInvariant()
    if ($Mode -eq 'None') {
        if ($key) { throw 'An empty-key selection cannot contain a product key.' }
        return ''
    }
    if ($Mode -eq 'Kms') {
        $matched=Get-PveKmsProductKey -ImageName $ImageName
        if (-not $matched) { throw 'No matching KMS client setup key exists for this Windows edition.' }
        if ($key -and $key -ne $matched) { throw 'The KMS key does not match the selected Windows edition.' }
        return $matched
    }
    if ($Mode -eq 'Legacy' -and $key -eq 'DEFAULT_KMS_KEY') { return 'default_kms_key' }
    Assert-PveProductKey -ProductKey $key
    return $key
}
