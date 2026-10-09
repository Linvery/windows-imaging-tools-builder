[CmdletBinding()]
param([string]$HivePath)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\Offline.Registry.ps1')
$directory=Join-Path $root ('local\registry-tests-'+[guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $directory -Force|Out-Null
$bad=Join-Path $directory 'not-a-hive'
[IO.File]::WriteAllText($bad,'not a Windows registry hive')
$rejected=$false
try{Get-OfflineImageState -HivePath $bad|Out-Null}catch{$rejected=$true}
if(-not$rejected){throw 'Malformed hive was accepted.'}
if($HivePath){
    $state=Get-OfflineImageState -HivePath $HivePath
    if($state -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'){throw ('Expected a generalized image, got: '+$state)}
    [PSCustomObject]@{MalformedHive='rejected';ActualImageState=$state}
}else{[PSCustomObject]@{MalformedHive='rejected';ActualImageState='not_requested'}}
