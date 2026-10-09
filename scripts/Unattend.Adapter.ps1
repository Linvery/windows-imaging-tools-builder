function script:Get-PveSetupProductKey {
    param($Image,[string]$RequestedProductKey,[ValidateSet('Legacy','Kms','Custom','None')][string]$Mode='Legacy')
    if ($Mode -ne 'Legacy') { return Resolve-PveProductKey -ImageName $Image.ImageName -Mode $Mode -ProductKey $RequestedProductKey }
    if ($RequestedProductKey) { return $RequestedProductKey }
    # Microsoft-published setup keys. These are not activation licenses.
    # https://learn.microsoft.com/windows-server/get-started/kms-client-activation-keys
    if ($Image.ImageName -match '^Windows Server 2025 SERVER(DATACENTER|STANDARD)(CORE)?$') { return Get-PveKmsProductKey -ImageName $Image.ImageName }
}
. (Join-Path $PSScriptRoot 'ProductKeys.Common.ps1')
function script:Set-PveUnattendElement {
    param([xml]$Document,[Xml.XmlElement]$Parent,[string]$Name,[string]$Value)
    $element=@($Parent.ChildNodes | Where-Object { $_.LocalName -eq $Name }) | Select-Object -First 1
    if (-not $element) { $element=$Document.CreateElement($Name,$Document.DocumentElement.NamespaceURI);$null=$Parent.AppendChild($element) }
    $element.InnerText=$Value
}
function script:Update-PveUnattendSettings {
    param([string]$Path,$Image,[switch]$AutomaticSetupKey)
    [xml]$document=[IO.File]::ReadAllText($Path)
    $namespace=[Xml.XmlNamespaceManager]::new($document.NameTable)
    $namespace.AddNamespace('u',$document.DocumentElement.NamespaceURI)
    if ($Image.ImageVersion.Major -ge 10) {
        $oobe=$document.SelectSingleNode('//u:settings[@pass="oobeSystem"]/u:component[@name="Microsoft-Windows-Shell-Setup"]/u:OOBE',$namespace)
        if (-not $oobe) { throw 'The unattended template has no OOBE configuration.' }
        foreach ($name in @('HideOnlineAccountScreens','HideLocalAccountScreen','HideOEMRegistrationScreen')) { Set-PveUnattendElement -Document $document -Parent $oobe -Name $name -Value 'true' }
    }
    if ($AutomaticSetupKey) {
        $specialize=$document.SelectSingleNode('//u:settings[@pass="specialize"]',$namespace)
        $component=$document.SelectSingleNode('//u:settings[@pass="specialize"]/u:component[@name="Microsoft-Windows-Security-SPP-UX"]',$namespace)
        if (-not $component) {
            $component=$document.CreateElement('component',$document.DocumentElement.NamespaceURI)
            foreach ($attribute in @{name='Microsoft-Windows-Security-SPP-UX';processorArchitecture=([string]$Image.ImageArchitecture).ToLowerInvariant();publicKeyToken='31bf3856ad364e35';language='neutral';versionScope='nonSxS'}.GetEnumerator()) { $component.SetAttribute($attribute.Key,$attribute.Value) }
            $null=$specialize.AppendChild($component)
        }
        Set-PveUnattendElement -Document $document -Parent $component -Name 'SkipAutoActivation' -Value 'true'
    }
    $settings=[Xml.XmlWriterSettings]::new()
    $settings.Encoding=[Text.UTF8Encoding]::new($false)
    $settings.Indent=$true
    $writer=[Xml.XmlWriter]::Create($Path,$settings)
    try { $document.Save($writer) } finally { $writer.Dispose() }
}
