[CmdletBinding(SupportsShouldProcess=$true)]
param([string]$ConfigPath,[switch]$SkipBootVerification,[Parameter(DontShow=$true)][switch]$InternalWorker,[Parameter(DontShow=$true)][string]$ResourceContextPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'scripts\Project.Common.ps1')
. (Join-Path $PSScriptRoot 'scripts\Build.Validation.ps1')
Assert-PowerShell51
$settings=Get-ProjectSettings
if(-not$ConfigPath){$ConfigPath=Join-Path $ProjectRoot 'local\image.ini'}
if(-not(Test-Path -LiteralPath $ConfigPath -PathType Leaf)){throw 'Generate a local image config with New-ImageConfig.ps1 first.'}
$priorWhatIf=$WhatIfPreference
try {
    $WhatIfPreference=$false
    if ($InternalWorker) { . (Join-Path $ProjectRoot 'scripts\Import-ImagingTools.ps1') -Settings $settings -ResourceContextPath $ResourceContextPath }
    else { . (Join-Path $ProjectRoot 'scripts\Import-ImagingTools.ps1') -Settings $settings }
    $config=Get-WindowsImageConfig -ConfigFilePath $ConfigPath
    $inputs=Assert-ImageBuildInputs -Settings $settings -Config $config -CheckHost
    $tools=Get-ImageServicingTools
}
finally{$WhatIfPreference=$priorWhatIf}
if(-not$PSCmdlet.ShouldProcess($config.image_path,'Build a Windows image using Hyper-V and Sysprep')){
    [PSCustomObject]@{OutputPath=$config.image_path;DiskGiB=([long]$config.disk_size/1GB);Upstream=$settings.UpstreamRoot;HostChecks=$inputs.HostChecks;DismVersion=$tools.DismVersion;BcdbootVersion=$tools.BcdbootVersion}
    return
}
Assert-Administrator
if (-not $InternalWorker) {
    . (Join-Path $ProjectRoot 'scripts\Build.Cancellation.ps1')
    Invoke-PveControlledBuild -ScriptPath $PSCommandPath -ConfigPath $ConfigPath -Settings $settings -Config $config -ServicingIsoPath $inputs.Software.ServicingIsoPath -SkipBootVerification:$SkipBootVerification
    return
}
. (Join-Path $ProjectRoot 'scripts\Build.Resources.ps1')
$resources=Get-PveBuildResources -ContextPath $ResourceContextPath
if ($resources.OutputPath -ine [IO.Path]::GetFullPath($config.image_path) -or $resources.AssetsRoot -ine [IO.Path]::GetFullPath($settings.AssetsRoot)) { throw 'Worker configuration differs from its resource owner.' }
$runId=$resources.RunId
$logDirectory=$resources.LogDirectory
$state=[ordered]@{Phase='starting';StartedUtc=[DateTime]::UtcNow.ToString('o');ConfigPath=[IO.Path]::GetFullPath($ConfigPath);OutputPath=$config.image_path;ImageName=$config.image_name;ImageVersion=$inputs.ImageVersion;ServicingTools=$tools;LogDirectory=$logDirectory}
function Save-BuildState {
    [IO.File]::WriteAllText((Join-Path $logDirectory 'status.json'),($state|ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))
}
$transcriptStarted=$false
$priorPath=$env:Path
try{
    Save-BuildState
    Start-Transcript -Path (Join-Path $logDirectory 'build-transcript.txt')|Out-Null
    $transcriptStarted=$true
    & (Get-Module WinImageBuilder) {
        param($Directory,$ToolPaths,$KeyMode)
        $script:PveRunLogDirectory=$Directory
        $script:PveServicingTools=$ToolPaths
        if ($KeyMode) { $script:PveProductKeyMode=$KeyMode }
    } $logDirectory $tools $inputs.Software.ProductKeyMode
    $servicingIso=$null
    $isoProperty=$inputs.Software.PSObject.Properties['ServicingIsoPath']
    if($isoProperty){$servicingIso=$isoProperty.Value}
    if(-not$servicingIso -and [IO.Path]::GetExtension($config.wim_file_path) -ieq '.iso'){$servicingIso=$config.wim_file_path}
    if(-not$servicingIso){throw 'Provide a matching Windows installer ISO with New-ImageConfig.ps1 -ServicingIsoPath for isolated Windows PE servicing.'}
    & (Get-Module WinImageBuilder) {param($IsoPath);$script:PveServicingIsoPath=$IsoPath} $servicingIso
    $state.ServicingMode='isolated_windows_pe';Save-BuildState
    $state.Phase='building';Save-BuildState
    $env:Path=(Split-Path -Parent $tools.DismPath)+';'+(Split-Path -Parent $tools.BcdbootPath)+';'+$priorPath
    New-WindowsOnlineImage -ConfigFilePath $ConfigPath
    if(-not(Test-Path -LiteralPath $config.image_path -PathType Leaf)){throw 'The builder returned without publishing an image.'}
    if(-not$SkipBootVerification){
        $state.Phase='verifying_boot';Save-BuildState
        $boot=& (Join-Path $ProjectRoot 'Verify-BuiltImage.ps1') -SourcePath $config.image_path -ConfigPath $ConfigPath -LogDirectory (Join-Path $logDirectory 'boot-verification') -ResourceContextPath $ResourceContextPath
        $state.BootVerification=$boot.Phase
    }else{$state.BootVerification='not_requested'}
    $state.Phase='complete';$state.CompletedUtc=[DateTime]::UtcNow.ToString('o')
    $state.SHA256=(Get-FileHash -LiteralPath $config.image_path -Algorithm SHA256).Hash
    $state.OutputBytes=(Get-Item -LiteralPath $config.image_path).Length
    Save-BuildState
    $resources=Get-PveBuildResources -ContextPath $ResourceContextPath
    $resources.Completed=$true
    Save-PveBuildResources -ContextPath $ResourceContextPath -Context $resources
}catch{
    $state.Phase='failed';$state.Error=$_.Exception.Message;Save-BuildState
    throw ('Build failed. Logs: '+$logDirectory+'. '+$_.Exception.Message)
}finally{$env:Path=$priorPath;if($transcriptStarted){Stop-Transcript|Out-Null}}
