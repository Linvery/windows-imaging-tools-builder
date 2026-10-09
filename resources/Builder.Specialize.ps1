$ErrorActionPreference='Stop'
if (-not (Test-Path -LiteralPath 'C:\UnattendResources\config.ini' -PathType Leaf)) { throw 'Specialize is intended for the imaging guest only.' }
$directory=Join-Path $env:ProgramData 'PveImageBuilder'
$state=[ordered]@{Phase='starting';StartedUtc=[DateTime]::UtcNow.ToString('o');InstallationType=$null;ClientPoliciesApplied=$false}
function Write-SpecializeState {
    param([string]$Message,[switch]$Failed)
    [IO.File]::WriteAllText((Join-Path $directory 'specialize-status.json'),($state|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $kvp='HKLM:\SOFTWARE\Microsoft\Virtual Machine\Auto'
    if (Test-Path -LiteralPath $kvp) {
        $name='ImageGenerationLog-Specialize'
        if ($Failed) { $name='ImageGenerationLog-ERROR' }
        Set-ItemProperty -LiteralPath $kvp -Name $name -Value $Message -ErrorAction SilentlyContinue
    }
    Write-Host $Message
}
try {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    Write-SpecializeState -Message 'Specialize started.'
    $state.InstallationType=[string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name InstallationType -ErrorAction Stop).InstallationType
    if ($state.InstallationType -eq 'Client') {
        foreach ($policy in @(@{Path='HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore';Name='AutoDownload';Value=2},@{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent';Name='DisableWindowsConsumerFeatures';Value=1})) {
            New-Item -Path $policy.Path -Force | Out-Null
            New-ItemProperty -LiteralPath $policy.Path -Name $policy.Name -Value $policy.Value -PropertyType DWord -Force | Out-Null
        }
        $state.ClientPoliciesApplied=$true
    }
    # Network rules are configured by Logon and the project installation hooks.
    # Do not wait on Store services or keyboard input during Windows setup.
    $state.Phase='complete'
    $state.CompletedUtc=[DateTime]::UtcNow.ToString('o')
    Write-SpecializeState -Message ('Specialize complete: '+$state.InstallationType)
    exit 0
} catch {
    $state.Phase='failed'
    $state.Error=$_.Exception.Message
    try { Write-SpecializeState -Message ('Specialize failed: '+$_.Exception.Message) -Failed } catch {}
    Write-Error $_ -ErrorAction Continue
    exit 1
}
