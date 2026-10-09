[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SourcePath,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [string]$LogDirectory,
    [string]$ToolManifestPath,
    [string]$BackupDirectory,
    [switch]$ReplaceExisting,
    [string]$ResourceContextPath
)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'scripts\Build.Resources.ps1')
$settings=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $projectRoot 'local\settings.json')|ConvertFrom-Json
if(-not$ToolManifestPath){$ToolManifestPath=$settings.QemuManifestPath}
if(-not$BackupDirectory){$BackupDirectory=Join-Path $settings.AssetsRoot 'archive\verified-builds'}
$utf8=[Text.UTF8Encoding]::new($false)
$source=[IO.Path]::GetFullPath($SourcePath)
$output=[IO.Path]::GetFullPath($OutputPath)
$sourceItem=Get-Item -LiteralPath $source -ErrorAction Stop
if($sourceItem.PSIsContainer){throw 'Source must be an offline disk-image file.'}
if([IO.Path]::GetExtension($output) -ne '.qcow2'){throw 'Output must have the .qcow2 extension.'}
if((Test-Path -LiteralPath $output) -and -not$ReplaceExisting){throw 'Output already exists. ReplaceExisting is required to replace a verified image.'}
$outputDir=[IO.Path]::GetDirectoryName($output)
New-Item -ItemType Directory -Path $outputDir -Force|Out-Null
$runId=Get-Date -Format 'yyyyMMdd-HHmmss'
$runId+='-'+[guid]::NewGuid().ToString('N').Substring(0,8)
if(-not$LogDirectory){$LogDirectory=Join-Path $settings.AssetsRoot ('logs\compression-'+$runId)}
$logDir=[IO.Path]::GetFullPath($LogDirectory)
New-Item -ItemType Directory -Path $logDir -Force|Out-Null
$manifest=Get-Content -Raw -Encoding UTF8 -LiteralPath $ToolManifestPath|ConvertFrom-Json
$qemu=[IO.Path]::GetFullPath($manifest.ExecutablePath)
if(-not$manifest.PublishedHashVerified -or (Get-FileHash -Algorithm SHA256 -LiteralPath $qemu).Hash -ne $manifest.ExecutableSha256){throw 'Pinned QEMU tool verification failed.'}
$candidate=Join-Path $outputDir ([IO.Path]::GetFileNameWithoutExtension($output)+'.compressing-'+$runId+'.qcow2')
$candidate=[IO.Path]::GetFullPath($candidate)
if([IO.Path]::GetDirectoryName($candidate) -ne $outputDir -or (Test-Path -LiteralPath $candidate)){throw 'Unexpected temporary output path.'}
$state=[ordered]@{Phase='preparing';Pid=$PID;SourcePath=$source;OutputPath=$output;CandidatePath=$candidate;StartedUtc=[DateTime]::UtcNow.ToString('o');ToolVersion=$manifest.Version;CompressionType='zlib';ConversionCoroutines=1;LogDirectory=$logDir}
function Save-CompressionState([string]$Phase){$state.Phase=$Phase;$state.UpdatedUtc=[DateTime]::UtcNow.ToString('o');[IO.File]::WriteAllText((Join-Path $logDir 'compression-status.json'),($state|ConvertTo-Json -Depth 8),$utf8)}
function Quote-NativeArgument([string]$Value){
    $escaped=[regex]::Replace($Value,'(\\*)"','$1$1\"')
    $escaped=[regex]::Replace($escaped,'(\\+)$','$1$1')
    return '"'+$escaped+'"'
}
function Invoke-Qemu([string[]]$Arguments,[string]$Name){
    $stdout=Join-Path $logDir ($Name+'.stdout.txt')
    $stderr=Join-Path $logDir ($Name+'.stderr.txt')
    $argumentLine=($Arguments|ForEach-Object{Quote-NativeArgument $_}) -join ' '
    $p=Start-Process -FilePath $qemu -ArgumentList $argumentLine -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -PassThru
    try{$null=$p.Handle;$p.WaitForExit();$exitCode=$p.ExitCode}
    finally{if(-not$p.HasExited){$p.Kill();$p.WaitForExit()}}
    $lines=@()
    foreach($file in @($stdout,$stderr)){if(Test-Path -LiteralPath $file){$lines+=@(Get-Content -Encoding UTF8 -LiteralPath $file)}}
    [IO.File]::WriteAllText((Join-Path $logDir ($Name+'.txt')),($lines -join [Environment]::NewLine),$utf8)
    if($exitCode -ne 0){throw "qemu-img $Name failed (exit $exitCode); inspect $logDir."}
}
Register-PveBuildFile -ContextPath $ResourceContextPath -Path $candidate
$committed=$false
try{
    Save-CompressionState 'inspecting_source'
    Invoke-Qemu -Arguments @('info','--output=json',$source) -Name 'source-info'
    $sourceInfo=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $logDir 'source-info.stdout.txt')|ConvertFrom-Json
    $sourceBytes=$sourceItem.Length
    $sourceWrite=$sourceItem.LastWriteTimeUtc
    Save-CompressionState 'compressing_qcow2'
    Invoke-Qemu -Arguments @('convert','-p','-c','-m','1','-f',$sourceInfo.format,'-O','qcow2','-o','compat=1.1,compression_type=zlib',$source,$candidate) -Name 'qemu-convert'
    Save-CompressionState 'checking_compressed_qcow2'
    Invoke-Qemu -Arguments @('check','-f','qcow2',$candidate) -Name 'qemu-check'
    Save-CompressionState 'comparing_compressed_payload'
    Invoke-Qemu -Arguments @('compare','-p','-f',$sourceInfo.format,'-F','qcow2',$source,$candidate) -Name 'qemu-compare'
    Invoke-Qemu -Arguments @('info','--output=json',$candidate) -Name 'compressed-info'
    $info=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $logDir 'compressed-info.stdout.txt')|ConvertFrom-Json
    $backingProperty=$info.PSObject.Properties['backing-filename']
    if($info.format -ne 'qcow2' -or $info.'virtual-size' -ne $sourceInfo.'virtual-size' -or ($backingProperty -and $backingProperty.Value)){throw 'Compressed output metadata is inconsistent with the source.'}
    $now=Get-Item -LiteralPath $source
    if($now.Length -ne $sourceBytes -or $now.LastWriteTimeUtc -ne $sourceWrite){throw 'Source changed during compression.'}
    $state.SHA256=(Get-FileHash -Algorithm SHA256 -LiteralPath $candidate).Hash
    $state.OutputBytes=(Get-Item -LiteralPath $candidate).Length
    $state.VirtualBytes=$info.'virtual-size'
    $state.SourceBytes=$sourceBytes
    $state.Check='passed'
    $state.PayloadCompare='passed'
    Save-CompressionState 'publishing_verified_output'
    $backupPath=$null
    if(Test-Path -LiteralPath $output){
        $backupRoot=[IO.Path]::GetFullPath($BackupDirectory)
        $backupFolder=Join-Path $backupRoot ('qcow2-before-compression-'+$runId)
        New-Item -ItemType Directory -Path $backupFolder -Force|Out-Null
        $backupPath=[IO.Path]::GetFullPath((Join-Path $backupFolder ([IO.Path]::GetFileName($output))))
        if(-not$backupPath.StartsWith($backupRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $backupPath)){throw 'Unexpected backup target.'}
        Move-Item -LiteralPath $output -Destination $backupPath
    }
    try{Move-Item -LiteralPath $candidate -Destination $output}
    catch{if($backupPath -and -not(Test-Path -LiteralPath $output)){Move-Item -LiteralPath $backupPath -Destination $output};throw}
    $committed=$true
    $state.PreviousOutputBackup=$backupPath
    $state.CompletedUtc=[DateTime]::UtcNow.ToString('o')
    Save-CompressionState 'complete'
    return [PSCustomObject]$state
}catch{
    $state.Error=$_.Exception.Message
    Save-CompressionState 'failed'
    throw
}finally{
    if(-not$committed -and (Test-Path -LiteralPath $candidate)){
        if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($candidate)) -ne $outputDir){throw 'Temporary-image deletion escaped the output directory.'}
        Remove-Item -LiteralPath $candidate -Force
    }
}
