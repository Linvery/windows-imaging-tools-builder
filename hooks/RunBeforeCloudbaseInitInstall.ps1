$ErrorActionPreference = "Stop"

function Write-TemplateStage {
    param([string]$Stage, [string]$Message)
    Write-Host "$Stage - $Message"
    if (Get-Command Write-Log -CommandType Function -ErrorAction SilentlyContinue) {
        Write-Log -Stage $Stage -StageLog $Message
    }
}

function Test-ApplicationFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $value = (Get-Item -LiteralPath $Path).VersionInfo.ProductVersion
    return -not [string]::IsNullOrWhiteSpace($value)
}

function Test-VirtioBundleInstalled {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $entries = @(Get-ItemProperty -Path $roots -ErrorAction SilentlyContinue)
    foreach ($entry in $entries) {
        if ($entry.DisplayName -eq 'Virtio-win-guest-tools') {
            return $true
        }
    }
    return $false
}

function Invoke-TemplateInstaller {
    param(
        [string]$Name,
        [string]$FilePath,
        [string]$Arguments,
        [ref]$RebootRequired
    )
    Write-TemplateStage -Stage ($Name + 'InstallStart') -Message 'Starting silent installation.'
    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments `
        -WindowStyle Hidden -PassThru
    # Wait for the installer itself; GUI descendants must not block imaging.
    $null = $process.Handle
    $process.WaitForExit()
    if ($process.ExitCode -notin @(0, 3010, 1641)) {
        throw "$Name installation failed: ExitCode=$($process.ExitCode). Check the installer log in C:\Windows\Temp."
    }
    if ($process.ExitCode -in @(3010, 1641)) { $RebootRequired.Value = $true }
}

try {
    if (-not (Test-Path -LiteralPath 'C:\UnattendResources\config.ini')) {
        throw 'This installation hook is intended for the imaging guest, not the build host.'
    }
    $resourceRoot = 'C:\UnattendResources\CustomResources'
    if (Test-Path -LiteralPath (Join-Path $resourceRoot 'Software.Selection.ps1')) {
        . (Join-Path $resourceRoot 'Software.Selection.ps1')
        $selection = Get-GuestSoftwareSelection -ResourceRoot $resourceRoot
    } else { $selection = [PSCustomObject]@{InstallChrome=$true;InstallVSCode=$true} }
    . (Join-Path $resourceRoot 'Package.Validation.ps1')
    foreach ($package in @(Get-SelectedImagePackages -SkipChrome:(-not $selection.InstallChrome) -SkipVSCode:(-not $selection.InstallVSCode))) {
        Assert-ImagePackage -Path (Join-Path $resourceRoot $package.File) -Package $package
    }

    $rebootRequired = $false
    $chrome = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
    if ($selection.InstallChrome -and -not (Test-ApplicationFile -Path $chrome)) {
        $msi = Join-Path $resourceRoot 'chrome-enterprise64.msi'
        $arguments = "/i `"$msi`" ALLUSERS=1 /qn /norestart /L*v `"C:\Windows\Temp\chrome-install.log`""
        Invoke-TemplateInstaller -Name 'Chrome' -FilePath 'msiexec.exe' `
            -Arguments $arguments -RebootRequired ([ref]$rebootRequired)
    }
    if ($selection.InstallChrome -and -not (Test-ApplicationFile -Path $chrome)) {
        throw 'Chrome installation verification failed.'
    }
    if ($selection.InstallChrome) {
        Write-TemplateStage -Stage 'ChromeInstall' -Message (
            'Google Chrome ' + (Get-Item -LiteralPath $chrome).VersionInfo.ProductVersion.Trim() + ' installed for all users.'
        )
    } else { Write-TemplateStage -Stage 'ChromeInstall' -Message 'Skipped by software selection.' }

    $code = "$env:ProgramFiles\Microsoft VS Code\Code.exe"
    if ($selection.InstallVSCode -and -not (Test-ApplicationFile -Path $code)) {
        $setup = Join-Path $resourceRoot 'VSCodeSetup-x64.exe'
        $arguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /MERGETASKS="addtopath,!runcode" /LOG="C:\Windows\Temp\vscode-install.log"'
        Invoke-TemplateInstaller -Name 'VSCode' -FilePath $setup `
            -Arguments $arguments -RebootRequired ([ref]$rebootRequired)
    }
    if ($selection.InstallVSCode -and -not (Test-ApplicationFile -Path $code)) {
        throw 'VS Code system installation verification failed.'
    }
    if ($selection.InstallVSCode) {
        Write-TemplateStage -Stage 'VSCodeInstall' -Message (
            'Visual Studio Code ' + (Get-Item -LiteralPath $code).VersionInfo.ProductVersion.Trim() + ' installed for all users.'
        )
    } else { Write-TemplateStage -Stage 'VSCodeInstall' -Message 'Skipped by software selection.' }

    if (-not (Test-VirtioBundleInstalled)) {
        $setup = Join-Path $resourceRoot 'virtio-win-guest-tools.exe'
        $arguments = '/install /quiet /norestart /log "C:\Windows\Temp\virtio-guest-tools-install.log"'
        Invoke-TemplateInstaller -Name 'VirtioGuestTools' -FilePath $setup `
            -Arguments $arguments -RebootRequired ([ref]$rebootRequired)
    }
    if (-not (Test-VirtioBundleInstalled)) { throw 'VirtIO guest tools bundle installation verification failed.' }
    if (-not (Get-Service -Name 'qemu-ga' -ErrorAction SilentlyContinue)) {
        throw 'The VirtIO guest tools installation did not create the QEMU Guest Agent service.'
    }
    Set-Service -Name 'qemu-ga' -StartupType Automatic
    Write-TemplateStage -Stage 'VirtioGuestToolsInstall' -Message 'Virtio-win-guest-tools installed, including QEMU Guest Agent.'

    if ($rebootRequired) {
        Write-TemplateStage -Stage 'SoftwareReboot' -Message 'Installer requested a reboot; imaging will resume after restart.'
        exit 1005
    }
    exit 0
}
catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
