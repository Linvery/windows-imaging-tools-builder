$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'scripts\Project.Common.ps1')
Assert-PowerShell51
$fixture=Join-Path $repo ('local\specialize tests '+[guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $fixture | Out-Null
$text=[IO.File]::ReadAllText((Join-Path $repo 'resources\Builder.Specialize.ps1'))
$text=$text.Replace("Join-Path `$env:ProgramData 'PveImageBuilder'",("'"+$fixture+"'"))
$text=$text.Replace('exit 0','return 0').Replace('exit 1','return 1')
$scriptBlock=[scriptblock]::Create($text)
& {
    $global:PveSpecializeTest=@{Type='Server';PolicyWrites=0;Fail=$false;Guest=$true;Errors=@()}
    function Test-Path {
        param($LiteralPath,$PathType)
        if ($LiteralPath -eq 'C:\UnattendResources\config.ini') { return $global:PveSpecializeTest.Guest }
        if ($LiteralPath -like 'HKLM:*') { return $true }
        Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
    }
    function Get-ItemProperty {
        param($LiteralPath,$Name,$ErrorAction)
        if ($global:PveSpecializeTest.Fail) { throw 'Simulated setup error.' }
        [PSCustomObject]@{InstallationType=$global:PveSpecializeTest.Type}
    }
    function New-Item {
        param($ItemType,$Path,[switch]$Force)
        if ($Path -like 'HKLM:*') { return }
        Microsoft.PowerShell.Management\New-Item -ItemType $ItemType -Path $Path -Force
    }
    function New-ItemProperty { param($LiteralPath,$Name,$Value,$PropertyType,[switch]$Force) $global:PveSpecializeTest.PolicyWrites++ }
    function Set-ItemProperty { param($LiteralPath,$Name,$Value,$ErrorAction) if($Name -eq 'ImageGenerationLog-ERROR'){$global:PveSpecializeTest.Errors+= $Value} }
    function Stop-Service { throw 'Specialize must not wait on Windows services.' }
    function Read-Host { throw 'Specialize must never wait for user input.' }
    foreach ($type in @('Server','Server Core','Client')) {
        $global:PveSpecializeTest.Type=$type
        $global:PveSpecializeTest.PolicyWrites=0
        $result=& $scriptBlock
        if ($result -ne 0) { throw 'Specialize did not complete.' }
        $state=Get-Content -Raw -LiteralPath (Join-Path $fixture 'specialize-status.json') | ConvertFrom-Json
        if ($state.Phase -ne 'complete' -or $state.InstallationType -ne $type) { throw 'Specialize proof does not match the selected OS.' }
        $expected=0
        if ($type -eq 'Client') { $expected=2 }
        if ($global:PveSpecializeTest.PolicyWrites -ne $expected) { throw 'Client policies were applied to the wrong OS.' }
    }
    $global:PveSpecializeTest.Fail=$true
    if ((& $scriptBlock 2>$null) -ne 1 -or -not $global:PveSpecializeTest.Errors.Count) { throw 'Setup error did not fail promptly with a host log.' }
    $global:PveSpecializeTest.Guest=$false
    $rejected=$false
    try { & $scriptBlock | Out-Null } catch { $rejected=$true }
    if (-not $rejected) { throw 'Specialize was allowed to run on the host.' }
    [PSCustomObject]@{Server='passed';ServerCore='passed';Client='passed';ErrorHandling='no user input; host error emitted';HostGuard='passed';RegistryAndServiceCalls='mocked'}
}
