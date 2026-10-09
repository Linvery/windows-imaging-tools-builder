$ErrorActionPreference='Stop'
$root=Join-Path $env:ProgramFiles 'Cloudbase Solutions\Cloudbase-Init'
if(-not(Test-Path -LiteralPath 'C:\UnattendResources\config.ini')){throw 'This installer is intended for the image build guest.'}
$default=@(Get-ChildItem -LiteralPath $root -Filter 'default.py' -File -Recurse|Where-Object{$_.FullName -like '*\cloudbaseinit\conf\default.py'})
if($default.Count -ne 1){throw 'Cloudbase-Init Python configuration module was not found uniquely.'}
$package=Split-Path -Parent $default[0].DirectoryName
$python=@(Get-ChildItem -LiteralPath $root -Filter 'python.exe' -File -Recurse|Where-Object{$_.DirectoryName -match '\\Python$'})
if($python.Count -ne 1){throw 'Cloudbase-Init Python runtime was not found uniquely.'}
$resources='C:\UnattendResources\CustomResources'
Copy-Item -LiteralPath (Join-Path $resources 'managedadmin.py') -Destination (Join-Path $package 'plugins\common\managedadmin.py') -Force
Copy-Item -LiteralPath (Join-Path $resources 'managed-admin-policy.json') -Destination (Join-Path $root 'conf\managed-admin-policy.json') -Force
& $python[0].FullName (Join-Path $resources 'configure-managed-admin.py') $default[0].FullName (Join-Path $root 'conf\cloudbase-init.conf') 'C:\Windows\Temp\managed-admin-plugin-order.json'
if($LASTEXITCODE -ne 0){throw 'Managed administrator plugin registration failed.'}
Write-Output 'Managed administrator plugin installed after password injection.'
