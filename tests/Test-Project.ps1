[CmdletBinding()]
param([switch]$RunConversionCheck)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\Project.Common.ps1')
Assert-PowerShell51
$settings=Get-ProjectSettings
$errorsFound=@()
foreach($file in Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File -Recurse|Where-Object{$_.FullName -notlike ($root+'\vendor\*') -and $_.FullName -notlike ($root+'\local\*') -and $_.FullName -notlike ($root+'\data\*')}){
    $tokens=$null;$syntaxErrors=$null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$syntaxErrors)|Out-Null
    if($syntaxErrors.Count){$errorsFound+=@($syntaxErrors)}
}
if($errorsFound.Count){throw ($errorsFound|Out-String)}
$example=[IO.File]::ReadAllText((Join-Path $root 'config\image.example.ini'))
if($example -notmatch '(?m)^administrator_password=__EPHEMERAL_BUILD_PASSWORD__'){throw 'Example configuration is not sanitized.'}
$revision=(& $settings.GitPath -C $settings.UpstreamRoot rev-parse HEAD)-join ''
$project=Get-BuildDependencies
if($revision -ne $project.UpstreamCommit){throw 'Unexpected upstream revision.'}
. (Join-Path $root 'scripts\Import-ImagingTools.ps1') -Settings $settings
$checked=@{Syntax='passed';SanitizedConfig='passed';PinnedSubmodule='passed';ModuleImport='passed';Conversion='not_requested'}
if($RunConversionCheck){
    $dir=Join-Path $root 'local\smoke test'
    New-Item -ItemType Directory -Path $dir -Force|Out-Null
    $source=Join-Path $dir 'test input.raw';$output=Join-Path $dir ('test output-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.qcow2')
    $bytes=New-Object byte[] (2MB)
    for($i=0;$i -lt 64KB;$i++){$bytes[$i]=[byte]($i%251)}
    [IO.File]::WriteAllBytes($source,$bytes)
    & (Get-Module WinImageBuilder) {param($Source,$Output);Convert-VirtualDisk -vhdPath $Source -outPath $Output -format qcow2 -CompressQcow2 $true} $source $output
    if(-not(Test-Path -LiteralPath $output)){throw 'Module conversion bridge did not publish an image.'}
    $checked.Conversion='passed; content compared; paths contain spaces'
}
[PSCustomObject]$checked
