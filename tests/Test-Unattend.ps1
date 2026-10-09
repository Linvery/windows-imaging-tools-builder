$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'scripts\Project.Common.ps1')
Assert-PowerShell51
$settings=Get-ProjectSettings
. (Join-Path $repo 'scripts\Import-ImagingTools.ps1') -Settings $settings
$directory=Join-Path $repo ('local\unattend tests '+[guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $directory | Out-Null
$checked=0
foreach ($name in @('Windows 11 Pro for Workstations','Windows Server 2025 SERVERSTANDARD','Windows Server 2025 SERVERSTANDARDCORE','Windows Server 2025 SERVERDATACENTER','Windows Server 2025 SERVERDATACENTERCORE')) {
    $image=[PSCustomObject]@{ImageArchitecture='AMD64';ImageName=$name;ImageVersion=[version]'10.0.26100.1';ImageInstallationType=$(if($name -like 'Windows Server*'){'Server'}else{'Client'})}
    $output=Join-Path $directory ('unattend-'+$checked+'.xml')
    & (Get-Module WinImageBuilder) {param($InputPath,$OutputPath,$Image); Generate-UnattendXml -inUnattendXmlPath $InputPath -outUnattendXmlPath $OutputPath -image $Image -administratorPassword 'Fixture!NeverUsedToBuild'} (Join-Path $settings.UpstreamRoot 'UnattendTemplate.xml') $output $image
    [xml]$xml=[IO.File]::ReadAllText($output)
    $ns=[Xml.XmlNamespaceManager]::new($xml.NameTable)
    $ns.AddNamespace('u',$xml.DocumentElement.NamespaceURI)
    $key=$xml.SelectSingleNode('//u:settings[@pass="specialize"]/u:component[@name="Microsoft-Windows-Shell-Setup"]/u:ProductKey',$ns)
    $expected=$null
    if ($name -like '*SERVERSTANDARD*') { $expected='TVRH6-WHNXV-R9WG3-9XRFY-MY832' }
    elseif ($name -like '*SERVERDATACENTER*') { $expected='D764K-2NDRG-47T6Q-P8T8W-YP6DF' }
    if ($expected) {
        if (-not $key -or $key.InnerText -ne $expected) { throw 'Server setup key is incorrect.' }
        $skip=$xml.SelectSingleNode('//u:component[@name="Microsoft-Windows-Security-SPP-UX"]/u:SkipAutoActivation',$ns)
        if (-not $skip -or $skip.InnerText -ne 'true') { throw 'Automatic activation was not suppressed.' }
    } elseif ($key) { throw 'A setup key was injected into the client image.' }
    foreach ($setting in @('HideOnlineAccountScreens','HideLocalAccountScreen','HideOEMRegistrationScreen')) {
        $node=$xml.SelectSingleNode(('//u:OOBE/u:'+$setting),$ns)
        if (-not $node -or $node.InnerText -ne 'true') { throw ('Missing modern OOBE setting: '+$setting) }
    }
    if (($xml.SelectNodes('//u:AutoLogon/u:Password/u:Value',$ns))[0].InnerText -ne 'Fixture!NeverUsedToBuild') { throw 'Automatic logon configuration changed.' }
    $checked++
}
. (Join-Path $repo 'scripts\Unattend.Adapter.ps1')
if ((Get-PveSetupProductKey -Image $image -RequestedProductKey 'AAAAA-BBBBB-CCCCC-DDDDD-EEEEE') -ne 'AAAAA-BBBBB-CCCCC-DDDDD-EEEEE') { throw 'Explicit product key was overwritten.' }
[PSCustomObject]@{ImageCases=$checked;ServerSetupKeys='passed';ModernOobe='passed';ClientKey='unchanged';ExplicitKey='preserved';AutoLogon='preserved'}
