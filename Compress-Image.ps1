[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$SourcePath,[Parameter(Mandatory=$true)][string]$OutputPath,[switch]$ReplaceExisting)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'scripts\Project.Common.ps1')
Assert-PowerShell51
& (Join-Path $ProjectRoot 'src\Compress-Qcow2Image.ps1') -SourcePath $SourcePath -OutputPath $OutputPath -ReplaceExisting:$ReplaceExisting
