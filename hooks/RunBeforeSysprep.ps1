$ErrorActionPreference = "Stop"

Write-Host "Running pre-Sysprep cleanup..."

Get-AppxPackage `
    -AllUsers `
    Microsoft.OneDriveSync |
    Remove-AppxPackage `
        -AllUsers `
        -ErrorAction SilentlyContinue

powercfg.exe /hibernate off
if ($LASTEXITCODE -ne 0) { throw 'Could not disable hibernation.' }

$resourceRoot = 'C:\UnattendResources\CustomResources'
if (Test-Path -LiteralPath (Join-Path $resourceRoot 'Software.Selection.ps1')) {
    . (Join-Path $resourceRoot 'Software.Selection.ps1')
    $selection = Get-GuestSoftwareSelection -ResourceRoot $resourceRoot
} else { $selection = [PSCustomObject]@{InstallChrome=$true;InstallVSCode=$true} }
$qga = Get-Service -Name 'qemu-ga' -ErrorAction Stop
$cloudbase = Get-Service -Name 'cloudbase-init' -ErrorAction Stop
$proof = [ordered]@{CheckedUtc=[DateTime]::UtcNow.ToString('o');InstallChrome=$selection.InstallChrome;InstallVSCode=$selection.InstallVSCode;QemuGuestAgent=($qga.StartType -eq 'Automatic');CloudbaseInit=($null -ne $cloudbase)}
foreach ($application in @(@{Selected=$selection.InstallChrome;Name='Chrome';Path=(Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe')},@{Selected=$selection.InstallVSCode;Name='VSCode';Path=(Join-Path $env:ProgramFiles 'Microsoft VS Code\Code.exe')})) {
    if ($application.Selected) {
        if (-not (Test-Path -LiteralPath $application.Path -PathType Leaf)) { throw ('Selected application missing: ' + $application.Name) }
        $proof[$application.Name+'Version'] = (Get-Item -LiteralPath $application.Path).VersionInfo.ProductVersion.Trim()
    }
}
if (-not $proof.QemuGuestAgent) { throw 'QEMU Guest Agent must start automatically.' }
$proofRoot=Join-Path $env:ProgramData 'PveImageBuilder'
New-Item -ItemType Directory -Path $proofRoot -Force|Out-Null
[IO.File]::WriteAllText((Join-Path $proofRoot 'build-verification.json'),($proof|ConvertTo-Json),[Text.UTF8Encoding]::new($false))

Write-Host "Pre-Sysprep cleanup completed."

exit 0
