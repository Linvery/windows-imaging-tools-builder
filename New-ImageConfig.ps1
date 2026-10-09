[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][Alias('SourcePath')][string]$WimPath,
    [string]$OutputPath,
    [string]$SwitchName = 'external',
    [string]$ImageName = 'Windows 11 Pro for Workstations',
    [string]$VirtioIsoPath,
    [string]$ServicingIsoPath,
    [ValidateRange(1,256)][int]$CpuCount = 4,
    [ValidateRange(2,1024)][int]$RamGiB = 8,
    [ValidateRange(64,65536)][int]$DiskGiB = 128,
    [string]$TimeZone = 'Eastern Standard Time',
    [switch]$InstallUpdates,
    [switch]$SkipChrome,
    [switch]$SkipVSCode,
    [string]$ConfigPath,
    [AllowEmptyString()][string]$ProductKey='',
    [ValidateSet('Legacy','Kms','Custom','None')][string]$ProductKeyMode='Legacy',
    [AllowEmptyString()][string]$KmsServer
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\Project.Common.ps1')
. (Join-Path $PSScriptRoot 'scripts\Configuration.Common.ps1')
$settings = Get-ProjectSettings
if ($PSBoundParameters.ContainsKey('ProductKey') -and $ProductKeyMode -eq 'Legacy') { $ProductKeyMode=$(if($ProductKey){'Custom'}else{'None'}) }
$selectedKey=Resolve-PveProductKey -ImageName $ImageName -Mode $ProductKeyMode -ProductKey $ProductKey
if (-not $PSBoundParameters.ContainsKey('KmsServer')) { $KmsServer=Get-PveDefaultKmsServer }
$KmsServer=(ConvertTo-PveKmsEndpoint -Address $KmsServer).Address
if (-not $OutputPath) { $OutputPath = Join-Path $settings.AssetsRoot ('output\' + (Get-DefaultImageFileName -ImageName $ImageName)) }
if (-not $ConfigPath) { $ConfigPath = Join-Path $ProjectRoot 'local\image.ini' }
if (-not $VirtioIsoPath) { $VirtioIsoPath=Find-VirtioInstallerIso -ProjectRoot $ProjectRoot -AssetsRoot $settings.AssetsRoot;if(-not$VirtioIsoPath){$VirtioIsoPath=Join-Path $settings.AssetsRoot 'iso\virtio-win.iso'} }
$source = [IO.Path]::GetFullPath($WimPath)
if(-not$ServicingIsoPath -and [IO.Path]::GetExtension($source) -ieq '.iso'){$ServicingIsoPath=$source}
if(-not$ServicingIsoPath){$ServicingIsoPath=Find-WindowsInstallerIso -ProjectRoot $ProjectRoot -AssetsRoot $settings.AssetsRoot}
if($ServicingIsoPath){$ServicingIsoPath=[IO.Path]::GetFullPath($ServicingIsoPath);if(-not(Test-Path -LiteralPath $ServicingIsoPath -PathType Leaf) -or [IO.Path]::GetExtension($ServicingIsoPath) -ine '.iso'){throw 'Windows PE servicing requires an existing Windows installer ISO.'}}
$output = [IO.Path]::GetFullPath($OutputPath)
$virtio = [IO.Path]::GetFullPath($VirtioIsoPath)
$config = [IO.Path]::GetFullPath($ConfigPath)
foreach ($entry in @{Source=$source;Output=$output;Virtio=$virtio;Config=$config;ImageName=$ImageName;SwitchName=$SwitchName;TimeZone=$TimeZone}.GetEnumerator()) { Assert-ConfigValue -Value $entry.Value -Name $entry.Key }
if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or [IO.Path]::GetExtension($source).ToLowerInvariant() -notin @('.iso','.wim')) { throw 'Select an existing Windows ISO or install.wim file.' }
if ([IO.Path]::GetExtension($output).ToLowerInvariant() -ne '.qcow2') { throw 'Output must have the .qcow2 extension.' }
if (Test-Path -LiteralPath $output) { throw 'Output already exists; choose a new output path.' }
if (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($output,'.vhdx'))) { throw 'The corresponding temporary VHDX already exists; choose a new output path.' }
if (-not (Test-Path -LiteralPath $virtio -PathType Leaf) -or [IO.Path]::GetExtension($virtio).ToLowerInvariant() -ne '.iso') { throw 'VirtIO ISO is missing or is not an ISO file.' }
$localRoot = [IO.Path]::GetFullPath((Join-Path $ProjectRoot 'local')).TrimEnd('\') + '\'
if (-not $config.StartsWith($localRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Generated configuration must be inside the project local directory.' }
if ($ProjectRoot.Contains(',')) { throw 'The upstream resource parser does not support a comma in the project path.' }
[TimeZoneInfo]::FindSystemTimeZoneById($TimeZone) | Out-Null
$packages = @(Get-SelectedImagePackages -SkipChrome:$SkipChrome -SkipVSCode:$SkipVSCode)
$virtioInstaller = Initialize-VirtioGuestTools -Settings $settings -VirtioIsoPath $virtio
$installerPaths = @{}
foreach ($package in $packages) {
    if ($package.Name -eq 'VirtIO') { $installer = $virtioInstaller }
    else { $installer = Find-ImagePackageInstaller -Package $package -Directories @((Join-Path $ProjectRoot 'data\custom-resources'),(Join-Path $settings.AssetsRoot 'custom-resources')) }
    if (-not $installer) {
        Assert-ImagePackage -Path (Join-Path $settings.AssetsRoot ('custom-resources\' + $package.File)) -Package $package
    }
    $installerPaths[$package.Name] = $installer
}
$runId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
$staged = Join-Path $ProjectRoot ('local\staged-resources\' + $runId)
New-Item -ItemType Directory -Path $staged -Force | Out-Null
foreach ($package in $packages) { Copy-Item -LiteralPath $installerPaths[$package.Name] -Destination (Join-Path $staged $package.File) }
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'resources') -File) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $staged $file.Name) }
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'scripts\Software.Selection.ps1') -Destination (Join-Path $staged 'Software.Selection.ps1')
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'scripts\Package.Validation.ps1') -Destination (Join-Path $staged 'Package.Validation.ps1')
$software = [ordered]@{SchemaVersion=1;InstallChrome=(-not $SkipChrome);InstallVSCode=(-not $SkipVSCode);ServicingIsoPath=$ServicingIsoPath;ProductKeyMode=$ProductKeyMode;KmsServer=$KmsServer;Packages=@($packages | Select-Object Name,File,Validation)}
[IO.File]::WriteAllText((Join-Path $staged 'software-selection.json'), ($software | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
$text = [IO.File]::ReadAllText((Join-Path $ProjectRoot 'config\image.example.ini'))
$password = 'Build!' + [guid]::NewGuid().ToString('N')
$text = $text.Replace('__EPHEMERAL_BUILD_PASSWORD__',$password).Replace('__WIM_PATH__',$source).Replace('__OUTPUT_PATH__',$output).Replace('__ASSET_ROOT__',$settings.AssetsRoot).Replace('__STAGED_RESOURCES__',$staged).Replace('__PROJECT_ROOT__',$ProjectRoot)
$keyValue='""'
if ($selectedKey) { $keyValue=$selectedKey }
$values = [ordered]@{image_name=$ImageName;product_key=$keyValue;external_switch=$SwitchName;virtio_iso_path=$virtio;cpu_count=[string]$CpuCount;ram_size=[string]([long]$RamGiB*1GB);disk_size=[string]([long]$DiskGiB*1GB);time_zone=$TimeZone;install_updates=$InstallUpdates.IsPresent.ToString()}
foreach ($key in $values.Keys) { $text = Set-ImageConfigValue -Text $text -Key $key -Value $values[$key] }
New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($config)) -Force | Out-Null
# The upstream parser requires an INI without a BOM.
[IO.File]::WriteAllText($config,$text,[Text.UTF8Encoding]::new($false))
[PSCustomObject]@{ConfigPath=$config;SourcePath=$source;ImageName=$ImageName;KmsServer=$KmsServer;OutputPath=$output;DiskGiB=$DiskGiB;StagedResources=$staged;InstallChrome=(-not $SkipChrome);InstallVSCode=(-not $SkipVSCode);BuildPassword='Generated automatically.'}
