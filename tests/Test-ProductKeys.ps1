$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'scripts\Project.Common.ps1')
Assert-PowerShell51
. (Join-Path $repo 'scripts\ProductKeys.Common.ps1')
. (Join-Path $repo 'scripts\Configuration.Common.ps1')
. (Join-Path $repo 'scripts\Builder.Workflow.ps1')
function Assert-KeyTest { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }
function Assert-KeyFailure {
    param([scriptblock]$Action)
    $failed=$false
    try { & $Action | Out-Null } catch { $failed=$true }
    Assert-KeyTest $failed 'Expected key validation failure.'
}
$catalog=Get-PveKmsCatalog
$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$aliases=0
foreach ($entry in $catalog.Entries) {
    Assert-PveProductKey -ProductKey $entry.Key
    foreach ($name in $entry.Names) {
        Assert-KeyTest ($seen.Add($name)) 'The catalog contains an ambiguous edition alias.'
        Assert-KeyTest ((Get-PveKmsProductKey -ImageName $name) -ceq $entry.Key) 'Catalog edition matched a different key.'
        $aliases++
    }
}
$workstation='NRG8B-VKK3Q-CXVCJ-9G2XF-6Q84J'
$datacenter='D764K-2NDRG-47T6Q-P8T8W-YP6DF'
Assert-KeyTest ((Get-PveKmsProductKey -ImageName 'Windows 11 Pro for Workstations') -eq $workstation) 'Win11 workstation key changed.'
Assert-KeyTest ((Get-PveKmsProductKey -ImageName 'Windows Server 2025 SERVERDATACENTERCORE') -eq $datacenter) 'Server Core key changed.'
Assert-KeyTest (-not (Get-PveKmsProductKey -ImageName 'Windows 11 Home')) 'Home was assigned a KMS key.'
Assert-KeyFailure { Resolve-PveProductKey -ImageName 'Windows 11 Pro for Workstations' -Mode Kms -ProductKey $datacenter }
& {
    $script:keyAnswers=New-Object 'System.Collections.Generic.Queue[string]'
    $script:keyMessages=New-Object 'System.Collections.Generic.List[string]'
    function Read-Host {
        param($Prompt,[switch]$AsSecureString)
        if (-not $script:keyAnswers.Count) { throw 'Key test input exhausted.' }
        $answer=$script:keyAnswers.Dequeue()
        if ($AsSecureString) {
            if (-not $answer) { return [Security.SecureString]::new() }
            return ConvertTo-SecureString $answer -AsPlainText -Force
        }
        return $answer
    }
    function Write-Host { param($Object,$ForegroundColor) $script:keyMessages.Add([string]$Object) }
    $script:keyAnswers.Enqueue('')
    $selected=Read-BuilderProductKey -ImageName 'Windows 11 Pro for Workstations'
    Assert-KeyTest ($selected.Mode -eq 'Kms' -and $selected.Key -eq $workstation) 'Default key choice did not use the selected edition.'
    $script:keyAnswers.Enqueue('2');$script:keyAnswers.Enqueue('')
    $selected=Read-BuilderProductKey -ImageName 'Windows Server 2025 SERVERDATACENTER'
    Assert-KeyTest ($selected.Mode -eq 'None' -and -not $selected.Key) 'Manual blank did not remain empty.'
    $custom='AAAAA-BBBBB-CCCCC-DDDDD-EEEEE'
    foreach ($answer in @('2','invalid-private-value',$custom.ToLowerInvariant())) { $script:keyAnswers.Enqueue($answer) }
    $selected=Read-BuilderProductKey -ImageName 'Windows 11 Pro'
    Assert-KeyTest ($selected.Mode -eq 'Custom' -and $selected.Key -eq $custom) 'Manual input was not normalized or retried.'
    Assert-KeyTest (($script:keyMessages -join ' ') -notmatch 'AAAAA|invalid-private-value') 'A manual key was disclosed by a prompt or error.'
    $script:keyAnswers.Enqueue('Q')
    Assert-KeyFailure { Read-BuilderProductKey -ImageName 'Windows 11 Pro' }
    $script:keyAnswers.Enqueue('2');$script:keyAnswers.Enqueue('Q')
    Assert-KeyFailure { Read-BuilderProductKey -ImageName 'Windows 11 Pro' }
    $script:keyAnswers.Enqueue('1');$script:keyAnswers.Enqueue('');$script:keyAnswers.Enqueue('')
    $selected=Read-BuilderProductKey -ImageName 'Windows 11 Home'
    Assert-KeyTest ($selected.Mode -eq 'None') 'Unsupported edition could select a KMS key.'
}
$fixture=Join-Path $repo ('local\product key tests '+[guid]::NewGuid().ToString('N').Substring(0,8))
foreach ($directory in @('scripts','config','resources','local','assets\iso','assets\custom-resources','assets\output')) { New-Item -ItemType Directory -Path (Join-Path $fixture $directory) -Force | Out-Null }
foreach ($file in @('New-ImageConfig.ps1','scripts\Project.Common.ps1','scripts\Configuration.Common.ps1','scripts\Package.Validation.ps1','scripts\ProductKeys.Common.ps1','scripts\Software.Selection.ps1','config\Kms.ClientKeys.psd1','config\image.example.ini')) { Copy-Item -LiteralPath (Join-Path $repo $file) -Destination (Join-Path $fixture $file) }
$settings=[PSCustomObject]@{ProjectRoot=$fixture;AssetsRoot=(Join-Path $fixture 'assets')}
[IO.File]::WriteAllText((Join-Path $fixture 'local\settings.json'),($settings|ConvertTo-Json))
foreach ($file in @('assets\iso\Windows.iso','assets\iso\virtio-win.iso','assets\custom-resources\virtio-win-guest-tools.exe')) { [IO.File]::WriteAllText((Join-Path $fixture $file),'Fixture; never used to build an image.') }
Import-Module (Join-Path $repo 'vendor\windows-imaging-tools\Config.psm1') -Force
$counter=0
foreach ($case in @(@{Edition='Windows 11 Pro for Workstations';Mode='Kms';Key='';Expected=$workstation},@{Edition='Windows Server 2025 SERVERDATACENTER';Mode='Kms';Key='';Expected=$datacenter},@{Edition='Windows Server 2025 SERVERDATACENTER';Mode='None';Key='';Expected=''},@{Edition='Windows 11 Pro';Mode='Custom';Key='AAAAA-BBBBB-CCCCC-DDDDD-EEEEE';Expected='AAAAA-BBBBB-CCCCC-DDDDD-EEEEE'})) {
    $parameters=@{WimPath=(Join-Path $fixture 'assets\iso\Windows.iso');ImageName=$case.Edition;ProductKeyMode=$case.Mode;ProductKey=$case.Key;OutputPath=(Join-Path $fixture ('assets\output\image-'+$counter+'.qcow2'));ConfigPath=(Join-Path $fixture ('local\configs\image-'+$counter+'.ini'));SkipChrome=$true;SkipVSCode=$true}
    $result=& (Join-Path $fixture 'New-ImageConfig.ps1') @parameters
    $parsed=Get-WindowsImageConfig -ConfigFilePath $result.ConfigPath
    Assert-KeyTest ([string]$parsed.product_key -ceq $case.Expected) 'The selected key did not reach the generated INI.'
    $selection=Get-Content -Raw -LiteralPath (Join-Path $result.StagedResources 'software-selection.json') | ConvertFrom-Json
    Assert-KeyTest ($selection.ProductKeyMode -eq $case.Mode) 'The selection mode did not reach staged metadata.'
    Assert-KeyTest (($result|ConvertTo-Json) -notmatch 'AAAAA|NRG8B|D764K') 'The configuration summary contains a product key.'
    $counter++
}
$realSettings=Get-Content -Raw -LiteralPath (Join-Path $repo 'local\settings.json') | ConvertFrom-Json
. (Join-Path $repo 'scripts\Import-ImagingTools.ps1') -Settings $realSettings
foreach ($mode in @('Kms','None','Custom')) {
    $image=[PSCustomObject]@{ImageName='Windows Server 2025 SERVERDATACENTER';ImageArchitecture='AMD64';ImageVersion=[version]'10.0.26100.1';ImageInstallationType='Server'}
    $requested=''
    $expected=$datacenter
    if ($mode -eq 'None') { $expected='' }
    elseif ($mode -eq 'Custom') { $requested='AAAAA-BBBBB-CCCCC-DDDDD-EEEEE';$expected=$requested }
    $xmlPath=Join-Path $fixture ('selected-'+$mode+'.xml')
    & (Get-Module WinImageBuilder) {param($InputPath,$OutputPath,$Image,$Mode,$Key);$script:PveProductKeyMode=$Mode;Generate-UnattendXml -inUnattendXmlPath $InputPath -outUnattendXmlPath $OutputPath -image $Image -productKey $Key -administratorPassword 'Fixture!NeverUsedToBuild'} (Join-Path $realSettings.UpstreamRoot 'UnattendTemplate.xml') $xmlPath $image $mode $requested
    [xml]$document=[IO.File]::ReadAllText($xmlPath)
    $ns=[Xml.XmlNamespaceManager]::new($document.NameTable);$ns.AddNamespace('u',$document.DocumentElement.NamespaceURI)
    $keyNode=$document.SelectSingleNode('//u:settings[@pass="specialize"]/u:component[@name="Microsoft-Windows-Shell-Setup"]/u:ProductKey',$ns)
    Assert-KeyTest ([string]$keyNode.InnerText -ceq $expected) 'Unattended setup ignored the key selection.'
}
[PSCustomObject]@{CatalogEntries=$catalog.Entries.Count;EditionAliases=$aliases;TwoOptionMenu='passed';SecureManualInput='passed';ExplicitBlank='preserved in INI and XML';WrongEdition='rejected';IndependentConfigurations=$counter;UnattendedModes='passed'}
