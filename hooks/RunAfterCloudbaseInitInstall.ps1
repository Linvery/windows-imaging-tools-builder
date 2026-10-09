$ErrorActionPreference = 'Stop'
$stage = 'ValidateGuest'

try {
    if (-not (Test-Path -LiteralPath 'C:\UnattendResources\config.ini')) {
        throw 'This hook is intended for the imaging guest, not the build host.'
    }
    $stage = 'ConfigureQemuGuestAgent'
    $service = Get-Service -Name 'qemu-ga' -ErrorAction SilentlyContinue
    if (-not $service) {
        throw 'QEMU Guest Agent service is missing after virtio-win-guest-tools installation.'
    }
    Set-Service -Name 'qemu-ga' -StartupType Automatic
    Write-Host 'QEMU Guest Agent is supplied by virtio-win-guest-tools; standalone MSI installation is skipped.'
    if (Get-Command Write-Log -CommandType Function -ErrorAction SilentlyContinue) {
        Write-Log -Stage 'QemuGa' -StageLog 'QEMU Guest Agent provided by VirtIO guest tools; automatic startup configured.'
    }

    $stage = 'PrepareLocalScripts'
    $source = 'C:\UnattendResources\CustomResources\Apply-GuestNetworkSettings.ps1'
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw 'Guest network settings script is missing.'
    }
    $localScripts = Join-Path $env:ProgramFiles 'Cloudbase Solutions\Cloudbase-Init\LocalScripts'
    New-Item -ItemType Directory -Path $localScripts -Force | Out-Null
    $resourceRoot='C:\UnattendResources\CustomResources'
    if (Test-Path -LiteralPath (Join-Path $resourceRoot 'Software.Selection.ps1') -PathType Leaf) {
        . (Join-Path $resourceRoot 'Software.Selection.ps1')
        $stage = 'ReadSoftwareSelection'
        $selection=Get-GuestSoftwareSelection -ResourceRoot $resourceRoot
        if ($selection.KmsServer) {
            $stage = 'StageKmsSettings'
            $endpoint=ConvertTo-PveKmsEndpoint -Address $selection.KmsServer
            $kmsSource=Join-Path $resourceRoot 'Apply-KmsSettings.ps1'
            $kmsTarget=Join-Path $localScripts '20-KmsSettings.ps1'
            if ((Test-Path -LiteralPath $kmsTarget) -and
                (Get-FileHash -Algorithm SHA256 -LiteralPath $kmsTarget).Hash -ne
                (Get-FileHash -Algorithm SHA256 -LiteralPath $kmsSource).Hash) { throw 'A different KMS LocalScript already exists; refusing to overwrite it.' }
            Copy-Item -LiteralPath $kmsSource -Destination $kmsTarget -Force
            $kmsSettings=[ordered]@{SchemaVersion=1;Host=$endpoint.Host;Port=$endpoint.Port}
            [IO.File]::WriteAllText((Join-Path $localScripts 'kms-settings.json'),($kmsSettings|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
            $stage = 'ApplyKmsSettings'
            & $kmsTarget
            $stage = 'StageWindowsActivation'
            $activationSource=Join-Path $resourceRoot 'Activate-Windows.ps1'
            $activationTarget=Join-Path $localScripts '30-WindowsActivation.ps1'
            if ((Test-Path -LiteralPath $activationTarget) -and
                (Get-FileHash -Algorithm SHA256 -LiteralPath $activationTarget).Hash -ne
                (Get-FileHash -Algorithm SHA256 -LiteralPath $activationSource).Hash) { throw 'A different Windows activation LocalScript already exists; refusing to overwrite it.' }
            # Cloudbase-Init runs this after 20-KmsSettings.ps1 on deployment, not during image construction.
            Copy-Item -LiteralPath $activationSource -Destination $activationTarget -Force
        }
    }
    $stage = 'StageGuestNetworkSettings'
    $target = Join-Path $localScripts '10-GuestNetworkSettings.ps1'
    if (Test-Path -LiteralPath $target) {
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash -ne
            (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash) {
            throw 'A different guest network LocalScript already exists; refusing to overwrite it.'
        }
    }
    else {
        Copy-Item -LiteralPath $source -Destination $target
    }
    $stage = 'ApplyGuestNetworkSettings'
    & $source
    $stage = 'InstallManagedAdministrator'
    & 'C:\UnattendResources\CustomResources\Install-ManagedAdministrator.ps1'
    exit 0
}
catch {
    $failure = $_
    $failureReport = [ordered]@{
        Stage = $stage
        Message = $failure.Exception.Message
        ExceptionType = $failure.Exception.GetType().FullName
        PositionMessage = $failure.InvocationInfo.PositionMessage
        ScriptStackTrace = $failure.ScriptStackTrace
        TimestampUtc = [DateTime]::UtcNow.ToString('o')
    }
    try {
        $diagnosticDirectory = 'C:\ProgramData\PveImageBuilder'
        New-Item -ItemType Directory -Path $diagnosticDirectory -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $diagnosticDirectory 'post-cloudbase-init-error.json'),
            ($failureReport | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    } catch { Write-Warning ('Could not save guest hook diagnostics: ' + $_.Exception.Message) }
    try {
        if (Get-Command Write-Log -CommandType Function -ErrorAction SilentlyContinue) {
            $location=$failure.InvocationInfo.ScriptName + ':' + $failure.InvocationInfo.ScriptLineNumber
            Write-Log -Stage 'PostCloudbaseInitError' -StageLog ($stage + ': ' + $failure.Exception.Message + ' (' + $location + ')')
        }
    } catch { Write-Warning ('Could not publish guest hook diagnostics: ' + $_.Exception.Message) }
    Write-Error $failure -ErrorAction Continue
    exit 1
}
