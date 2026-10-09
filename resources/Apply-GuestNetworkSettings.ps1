$ErrorActionPreference = 'Stop'

# Runs inside the image guest during build and again through Cloudbase-Init LocalScripts.
$cloudbaseRoot = Join-Path $env:ProgramFiles 'Cloudbase Solutions\Cloudbase-Init'
if (-not (Test-Path -LiteralPath $cloudbaseRoot)) {
    throw 'Cloudbase-Init is not installed. Do not run this guest settings script on the build host.'
}

Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled False
$enabledProfiles = @(Get-NetFirewallProfile | Where-Object { [string]$_.Enabled -ne 'False' })
if ($enabledProfiles.Count -gt 0) {
    throw 'One or more Windows Firewall profiles remain enabled.'
}

# Keep Remote Desktop enabled with Network Level Authentication.
Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' `
    -Name 'fDenyTSConnections' -Value 0
Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
    -Name 'UserAuthentication' -Value 1
Set-Service -Name 'TermService' -StartupType Automatic

$message = 'Guest firewall disabled for Domain/Private/Public; Remote Desktop enabled with NLA.'
Write-Output $message
if (Get-Command Write-Log -CommandType Function -ErrorAction SilentlyContinue) {
    Write-Log -Stage 'GuestNetworkSettings' -StageLog $message
}
