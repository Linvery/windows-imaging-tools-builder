[CmdletBinding()]
param([string]$AssetsRoot, [string]$SourcePath, [switch]$ConfigureOnly)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\Project.Common.ps1')
. (Join-Path $PSScriptRoot 'scripts\Configuration.Common.ps1')
. (Join-Path $PSScriptRoot 'scripts\Builder.Workflow.ps1')
try {
    Show-BuilderPreparationGuide
    Invoke-ImageBuilderWizard -AssetsRoot $AssetsRoot -SourcePath $SourcePath -ConfigureOnly:$ConfigureOnly
} catch [OperationCanceledException] {
    Write-Host $_.Exception.Message
} catch {
    Write-Error ('镜像构建已停止：' + $_.Exception.Message)
    exit 1
}
