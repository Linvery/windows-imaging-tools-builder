function Read-BuilderText {
    param([string]$Prompt, [string]$Default, [scriptblock]$Validate)
    while ($true) {
        $label = $Prompt
        if ($Default) { $label += ' [' + $Default + ']' }
        $value = (Read-Host ($label + '，输入 Q 取消')).Trim()
        if ($value -ieq 'q') { throw [OperationCanceledException]::new('用户取消了向导。') }
        if (-not $value) { $value = $Default }
        if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) { $value = $value.Substring(1,$value.Length-2) }
        try {
            Assert-ConfigValue -Value $value -Name $Prompt
            if ($Validate) { & $Validate $value | Out-Null }
            return $value
        } catch { Write-Host ('输入无效：' + $_.Exception.Message) -ForegroundColor Yellow }
    }
}
function Get-BuilderDownloadLinks {
    [PSCustomObject]@{
        WindowsIso='https://massgrave.dev/genuine-installation-media'
        VirtioIso='https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso'
        Chrome='https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'
        VSCode='https://update.code.visualstudio.com/latest/win32-x64/stable'
    }
}
function Show-BuilderPreparationGuide {
    $links=Get-BuilderDownloadLinks
    Write-Host '开始前请准备以下资源：' -ForegroundColor Cyan
    Write-Host ('Windows ISO 或 WIM 放入 '+(Join-Path $ProjectRoot 'data\iso')+'，向导会列出文件供编号选择；也可手动指定路径。')
    Write-Host ('Windows ISO 下载：'+$links.WindowsIso)
    Write-Host ('VirtIO ISO 也放入 data\iso，guest-tools 会自动从 ISO 提取。最新下载：'+$links.VirtioIso)
    Write-Host ('Chrome 和 VS Code 可选；安装包放入 data\custom-resources。Chrome x64 MSI：'+$links.Chrome)
    Write-Host ('VS Code x64 系统安装包：'+$links.VSCode)
    Write-Host 'Chrome、VS Code 验证有效厂商签名，不限制版本，下载后无需改名；VirtIO 只检查 guest-tools 文件名。'
    Write-Host '没有 Hyper-V 外部交换机时会询问是否创建。回车使用默认值，输入 Q 取消。'
    Write-Host ''
}
function Read-BuilderBoolean {
    param([string]$Prompt, [bool]$Default=$true)
    $defaultValue = 'Y'
    if (-not $Default) { $defaultValue = 'N' }
    $value = Read-BuilderText -Prompt ($Prompt + ' (Y/N)') -Default $defaultValue -Validate {
        param($answer)
        if ($answer -notin @('y','n','yes','no')) { throw '请输入 Y 或 N。' }
    }
    return $value -in @('y','yes')
}
function Read-BuilderNumber {
    param([string]$Prompt, [int]$Default, [int]$Minimum, [int]$Maximum)
    $value = Read-BuilderText -Prompt ($Prompt + " ($Minimum-$Maximum)") -Default ([string]$Default) -Validate {
        param($answer)
        $parsed = 0
        if (-not [int]::TryParse($answer,[ref]$parsed) -or $parsed -lt $Minimum -or $parsed -gt $Maximum) { throw '数值超出范围。' }
    }
    return [int]$value
}
function Read-BuilderChoice {
    param([string]$Prompt, [object[]]$Items, [scriptblock]$Label, [int]$DefaultIndex=0)
    if (-not $Items.Count) { throw ('没有可选择的项目：' + $Prompt) }
    Write-Host $Prompt -ForegroundColor Cyan
    for ($index=0; $index -lt $Items.Count; $index++) {
        $description = [string]$Items[$index]
        if ($Label) { $description = & $Label $Items[$index] }
        Write-Host ('  {0}. {1}' -f ($index+1),$description)
    }
    $number = Read-BuilderNumber -Prompt '选择编号' -Default ($DefaultIndex+1) -Minimum 1 -Maximum $Items.Count
    return $Items[$number-1]
}
function Read-BuilderProductKey {
    param([string]$ImageName)
    $matched=Get-PveKmsProductKey -ImageName $ImageName
    $defaultIndex=0
    $label='当前版本无预置 KMS 密钥（不可选）'
    if ($matched) { $label=$matched+'（KMS密钥）' }
    else { $defaultIndex=1 }
    $items=@([PSCustomObject]@{Mode='Kms';Label=$label},[PSCustomObject]@{Mode='Custom';Label='自行填写/留空'})
    while ($true) {
        $choice=Read-BuilderChoice -Prompt '选择产品密钥' -Items $items -DefaultIndex $defaultIndex -Label {param($item) $item.Label}
        if ($choice.Mode -eq 'Kms') {
            if (-not $matched) { Write-Host '此版本没有匹配的 KMS 安装密钥，请选择第二项。' -ForegroundColor Yellow;continue }
            return [PSCustomObject]@{Mode='Kms';Key=$matched;Description='使用当前版本匹配的 KMS 安装密钥'}
        }
        while ($true) {
            $inputValue=Read-Host '填写产品密钥，直接回车留空，输入 Q 取消（输入隐藏）' -AsSecureString
            $value=''
            if ($inputValue -is [Security.SecureString]) {
                $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($inputValue)
                try { $value=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
                finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer);$inputValue.Dispose() }
            } else { $value=[string]$inputValue }
            $value=$value.Trim().ToUpperInvariant()
            if ($value -eq 'Q') { throw [OperationCanceledException]::new('用户取消了向导。') }
            if (-not $value) { return [PSCustomObject]@{Mode='None';Key='';Description='留空'} }
            try { Assert-PveProductKey -ProductKey $value }
            catch { Write-Host '密钥格式应为 XXXXX-XXXXX-XXXXX-XXXXX-XXXXX，请重新填写。' -ForegroundColor Yellow;continue }
            return [PSCustomObject]@{Mode='Custom';Key=$value;Description='自行填写（不显示密钥）'}
        }
    }
}
function Read-BuilderKmsServer {
    $default=Get-PveDefaultKmsServer
    $choice=Read-BuilderChoice -Prompt '选择 KMS 地址' -Items @($default,'自定义输入/留空')
    if ($choice -eq $default) { return [PSCustomObject]@{Address=$default;Description=$default} }
    while ($true) {
        $value=(Read-Host '填写 KMS 地址（域名或 IP，可加 :端口），直接回车留空，输入 Q 取消').Trim()
        if ($value -ieq 'q') { throw [OperationCanceledException]::new('用户取消了向导。') }
        try { $endpoint=ConvertTo-PveKmsEndpoint -Address $value }
        catch { Write-Host ('输入无效：'+$_.Exception.Message) -ForegroundColor Yellow;continue }
        $description=$endpoint.Address
        if (-not $description) { $description='留空（不设置 KMS 地址）' }
        return [PSCustomObject]@{Address=$endpoint.Address;Description=$description}
    }
}
function Assert-BuilderFile {
    param([string]$Path, [string[]]$Extensions)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw '文件不存在。' }
    if ($Extensions -and [IO.Path]::GetExtension($Path).ToLowerInvariant() -notin $Extensions) { throw ('支持的文件类型：' + ($Extensions -join ', ')) }
}
function Get-BuilderSourceCandidates {
    param([string]$AssetsRoot, [string]$SourcePath)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($directory in @((Join-Path $ProjectRoot 'data\iso'),(Join-Path $AssetsRoot 'iso'))) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $directory -File | Where-Object {
            $_.Extension.ToLowerInvariant() -in @('.iso','.wim') -and $_.Name -notlike '*virtio*'
        } | Sort-Object Name)) {
            if ($seen.Add($file.FullName)) {
                $label = $file.FullName
                if ([IO.Path]::GetFullPath($directory) -ieq [IO.Path]::GetFullPath((Join-Path $ProjectRoot 'data\iso'))) { $label = 'data\iso\' + $file.Name }
                [PSCustomObject]@{Path=$file.FullName;Label=$label}
            }
        }
    }
    if ($SourcePath) {
        try {
            Assert-BuilderFile -Path $SourcePath -Extensions @('.iso','.wim')
            $fullPath = [IO.Path]::GetFullPath($SourcePath)
            if ($seen.Add($fullPath)) { [PSCustomObject]@{Path=$fullPath;Label=$fullPath} }
        } catch {}
    }
}
function Read-BuilderInstallationSource {
    param([string]$AssetsRoot, [string]$SourcePath)
    while ($true) {
        $items = @(Get-BuilderSourceCandidates -AssetsRoot $AssetsRoot -SourcePath $SourcePath)
        $defaultIndex = 0
        if ($SourcePath) {
            $defaultIndex = $items.Count
            try {
                $fullPath = [IO.Path]::GetFullPath($SourcePath)
                for ($index=0; $index -lt $items.Count; $index++) { if ($items[$index].Path -ieq $fullPath) { $defaultIndex=$index; break } }
            } catch {}
        }
        if (-not $items.Count) { Write-Host '未发现 Windows ISO 或 WIM，可手动指定路径，或先将文件放入 data\iso。' -ForegroundColor Yellow }
        $items += [PSCustomObject]@{Path=$null;Label='手动输入其他 ISO 或 install.wim 路径'}
        $chosen = Read-BuilderChoice -Prompt '选择 Windows 安装源（优先列出 data\iso）' -Items $items -DefaultIndex $defaultIndex -Label { param($item) $item.Label }
        if (-not $chosen.Path) {
            $path = Read-BuilderText -Prompt 'Windows ISO 或 install.wim 完整路径' -Default $SourcePath -Validate { param($candidate) Assert-BuilderFile -Path $candidate -Extensions @('.iso','.wim') }
            return [IO.Path]::GetFullPath($path)
        }
        try { Assert-BuilderFile -Path $chosen.Path -Extensions @('.iso','.wim'); return $chosen.Path }
        catch { Write-Host ('安装源不可用：' + $_.Exception.Message + '，请重新选择。') -ForegroundColor Yellow; $SourcePath=$null }
    }
}
function Get-BuilderSourceImages {
    param([string]$SourcePath)
    $source = [IO.Path]::GetFullPath($SourcePath)
    $mountedHere = $false
    try {
        $wim = $source
        if ([IO.Path]::GetExtension($source) -ieq '.iso') {
            $diskImage = Get-DiskImage -ImagePath $source
            if (-not $diskImage.Attached) {
                Mount-DiskImage -ImagePath $source -StorageType ISO | Out-Null
                $mountedHere = $true
            }
            $volumes = @(Get-DiskImage -ImagePath $source | Get-Volume | Where-Object DriveLetter)
            if ($volumes.Count -ne 1) { throw '无法确定 ISO 盘符。' }
            $wim = $volumes[0].DriveLetter + ':\sources\install.wim'
            if (-not (Test-Path -LiteralPath $wim -PathType Leaf)) { throw 'ISO 中没有 sources\install.wim。install.esd 请先导出为 WIM。' }
        }
        $images = @(Get-WimFileImagesInfo -WimFilePath $wim)
        if (-not $images.Count) { throw '安装源没有可读取的 Windows 版本。' }
        return $images
    } finally {
        if ($mountedHere) { Dismount-DiskImage -ImagePath $source | Out-Null }
    }
}
function Get-BuilderAdk {
    $root = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64'
    $oscdimg = Join-Path $root 'Oscdimg\oscdimg.exe'
    if (-not (Test-Path -LiteralPath $oscdimg -PathType Leaf)) {
        throw '未找到 Windows ADK 的 Deployment Tools（oscdimg.exe）。请运行 ADK 安装程序，勾选 Deployment Tools（部署工具）后重新运行向导。下载：https://learn.microsoft.com/windows-hardware/get-started/adk-install'
    }
    return [PSCustomObject]@{OscdimgPath=$oscdimg;OscdimgVersion=(Get-Item -LiteralPath $oscdimg).VersionInfo.FileVersion}
}
function Get-BuilderHost {
    param([switch]$AllowMissingExternalSwitch)
    Write-Host '正在检查构建环境……' -ForegroundColor Cyan
    try { Assert-PowerShell51 } catch { throw '请使用 Windows PowerShell 5.1（powershell.exe）运行向导。' }
    try { Assert-Administrator } catch { throw '当前没有管理员权限，请以管理员身份打开 Windows PowerShell 后重新运行。' }
    if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
        throw '未找到 Hyper-V 管理模块。请在支持 Hyper-V 的 Windows 上启用 Hyper-V 平台和管理工具，并重启电脑。安装说明：https://learn.microsoft.com/virtualization/hyper-v-on-windows/quick-start/enable-hyper-v'
    }
    try { Import-Module Hyper-V -ErrorAction Stop }
    catch { throw ('无法加载 Hyper-V 管理模块，请检查 Hyper-V 管理工具是否完整安装。'+$_.Exception.Message) }
    $service = Get-Service -Name vmms -ErrorAction SilentlyContinue
    if (-not $service -or $service.Status -ne 'Running') {
        throw 'Hyper-V 虚拟机管理服务（vmms）未运行。请启用 Hyper-V 平台并重启电脑；已安装时请检查该服务。'
    }
    $system = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    if (-not $system.HypervisorPresent) {
        throw 'Hyper-V 虚拟机监控程序未运行。请确认已启用 Hyper-V、BIOS/UEFI 中的硬件虚拟化，并在启用后重启电脑。'
    }
    try {
        Get-VMHost -ErrorAction Stop | Out-Null
        $switches = @(Get-VMSwitch -ErrorAction Stop | Where-Object SwitchType -eq 'External')
    } catch { throw ('无法管理 Hyper-V，请检查当前账号的管理员或 Hyper-V 管理员权限，以及 vmms 服务。'+$_.Exception.Message) }
    $adk = Get-BuilderAdk
    Write-Host ('环境检查通过：Windows PowerShell 5.1、管理员权限、Hyper-V、ADK Deployment Tools（oscdimg {0}）。' -f $adk.OscdimgVersion) -ForegroundColor Green
    if (-not $switches.Count -and -not $AllowMissingExternalSwitch) { throw '没有可用的 Hyper-V 外部交换机，请运行 Start-ImageBuilder.ps1 按提示创建。' }
    return [PSCustomObject]@{Switches=$switches;LogicalProcessors=[int]$system.NumberOfLogicalProcessors;MemoryGiB=[int][Math]::Floor($system.TotalPhysicalMemory/1GB);Adk=$adk}
}
function Initialize-BuilderExternalSwitches {
    param([object[]]$Switches)
    if($Switches.Count){return $Switches}
    Write-Host '未找到 Hyper-V 外部交换机。' -ForegroundColor Yellow
    if(-not(Read-BuilderBoolean -Prompt '是否创建一个外部交换机' -Default $false)){
        throw [OperationCanceledException]::new('未创建外部交换机，向导已停止。')
    }
    $adapters=@(Get-NetAdapter -Physical -ErrorAction Stop|Where-Object Status -eq 'Up'|Sort-Object Name)
    if(-not$adapters.Count){throw '没有已连接的物理网卡，请连接网络后重新运行向导。'}
    $adapter=Read-BuilderChoice -Prompt '选择外部交换机使用的物理网卡' -Items $adapters -Label {param($item) '{0} — {1}（{2}）' -f $item.Name,$item.InterfaceDescription,$item.LinkSpeed}
    $name=Read-BuilderText -Prompt '外部交换机名称' -Default 'external' -Validate {
        param($candidate)
        if(Get-VMSwitch -Name $candidate -ErrorAction SilentlyContinue){throw '此名称已被其他交换机使用，请换一个名称。'}
    }
    Write-Host ('将在网卡“{0}”上创建“{1}”，并允许主机共享该网卡。创建时主机网络可能短暂中断。' -f $adapter.Name,$name) -ForegroundColor Yellow
    if(-not(Read-BuilderBoolean -Prompt '确认创建' -Default $false)){
        throw [OperationCanceledException]::new('已取消创建外部交换机。')
    }
    try{
        $created=New-VMSwitch -Name $name -NetAdapterName $adapter.Name -AllowManagementOS $true -ErrorAction Stop
        if($created.SwitchType -ne 'External'){throw '创建结果不是外部交换机。'}
    }catch{throw ('创建外部交换机失败：'+$_.Exception.Message+'。请检查所选网卡和 Hyper-V 网络配置。')}
    Write-Host ('已创建外部交换机：'+$name) -ForegroundColor Green
    return $created
}
function Assert-BuilderCapacity {
    param([int]$CpuCount,[long]$RamBytes,[int]$HostCpuCount,[long]$HostRamBytes)
    if($CpuCount -lt 1 -or $CpuCount -gt $HostCpuCount -or $RamBytes -lt 2GB -or $RamBytes -gt $HostRamBytes){throw 'Configured CPU or memory exceeds this build host.'}
}
function Get-BuilderToolStatus {
    param($Settings)
    if (-not (Test-Path -LiteralPath $Settings.QemuManifestPath -PathType Leaf)) { return $false }
    try {
        $tool = Get-Content -Raw -Encoding UTF8 -LiteralPath $Settings.QemuManifestPath | ConvertFrom-Json
        $project = Get-BuildDependencies
        return $tool.Version -eq $project.Qemu.Version -and $tool.PublishedHashVerified -and (Test-Path -LiteralPath $tool.ExecutablePath -PathType Leaf) -and (Get-FileHash -Algorithm SHA256 -LiteralPath $tool.ExecutablePath).Hash -eq $project.Qemu.ExecutableSHA256
    } catch { return $false }
}
function Assert-BuilderOutput {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetExtension($full) -ine '.qcow2') { throw '输出文件必须以 .qcow2 结尾。' }
    if (Test-Path -LiteralPath $full) { throw '输出已经存在，请选择新文件名。' }
    if (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($full,'.vhdx'))) { throw '对应的临时 VHDX 已经存在，请选择新文件名。' }
    if (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($full,'.raw'))) { throw '对应的临时 RAW 已经存在，请选择新文件名。' }
}
function Assert-BuilderDiskSpace {
    param([string]$OutputPath, [int]$DiskGiB)
    $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($OutputPath))
    if ($root -notmatch '^[A-Za-z]:\\$') { throw '请使用本机磁盘上的输出路径。' }
    $drive = Get-PSDrive -Name $root.Substring(0,1) -PSProvider FileSystem
    $required = ([long]$DiskGiB*2+20)*1GB
    if ($drive.Free -lt $required) { throw ('空间不足：建议至少 {0} GiB 可用空间（系统盘、转换和启动验收副本）。' -f ($required/1GB)) }
}
function Initialize-BuilderProject {
    param([string]$AssetsRoot)
    & (Join-Path $ProjectRoot 'Initialize-Project.ps1') -AssetsRoot $AssetsRoot | Out-Null
}
function New-BuilderConfiguration {
    param([hashtable]$Parameters)
    & (Join-Path $ProjectRoot 'New-ImageConfig.ps1') @Parameters
}
function Invoke-BuilderAction {
    param([string]$Action, [string]$ConfigPath)
    if ($Action -eq '预检') { & (Join-Path $ProjectRoot 'Build-Image.ps1') -ConfigPath $ConfigPath -WhatIf }
    elseif ($Action -eq '开始构建') { & (Join-Path $ProjectRoot 'Build-Image.ps1') -ConfigPath $ConfigPath }
}
function Initialize-BuilderTools {
    param($Settings)
    if (Get-BuilderToolStatus -Settings $Settings) { return }
    Write-Host '尚未准备或未通过校验的固定版本 qemu-img。' -ForegroundColor Yellow
    if (-not (Read-BuilderBoolean -Prompt '是否立刻下载 QEMU 与 7-Zip？' -Default $true)) { throw '请先运行 Install-QemuImageTool.ps1 准备工具。' }
    & (Join-Path $ProjectRoot 'Install-QemuImageTool.ps1') | Out-Host
}
function Initialize-BuilderPackages {
    param($Settings, [string]$VirtioIsoPath, [switch]$SkipChrome, [switch]$SkipVSCode)
    foreach ($package in @(Get-SelectedImagePackages -SkipChrome:$SkipChrome -SkipVSCode:$SkipVSCode)) {
        if($package.File -eq 'virtio-win-guest-tools.exe'){
            Initialize-VirtioGuestTools -Settings $Settings -VirtioIsoPath $VirtioIsoPath|Out-Null
            continue
        }
        $destination = Join-Path $Settings.AssetsRoot ('custom-resources\' + $package.File)
        $source = Find-ImagePackageInstaller -Package $package -Directories @((Join-Path $ProjectRoot 'data\custom-resources'),(Join-Path $Settings.AssetsRoot 'custom-resources'))
        if ($source) {
            if ([IO.Path]::GetFullPath($source) -ine [IO.Path]::GetFullPath($destination)) { Copy-Item -LiteralPath $source -Destination $destination -Force }
            continue
        }
        Write-Host ('需要 {0} 安装包，验证厂商签名，无需改名。' -f $package.Name) -ForegroundColor Yellow
        $links=Get-BuilderDownloadLinks
        if($package.File -eq 'chrome-enterprise64.msi'){Write-Host ('Chrome Enterprise x64 MSI 下载：'+$links.Chrome)}
        elseif($package.File -like 'VSCodeSetup-*'){Write-Host ('VS Code x64 系统安装包下载：'+$links.VSCode)}
        $source = Read-BuilderText -Prompt '安装包完整路径（可选择 data\custom-resources 中的文件）' -Validate {
            param($candidate)
            Assert-ImagePackage -Path $candidate -Package $package
        }
        if ([IO.Path]::GetFullPath($source) -ine [IO.Path]::GetFullPath($destination)) { Copy-Item -LiteralPath $source -Destination $destination -Force }
    }
}
function Invoke-ImageBuilderWizard {
    param([string]$AssetsRoot, [string]$SourcePath, [switch]$ConfigureOnly)
    Write-Host 'Windows / Proxmox 镜像构建向导' -ForegroundColor Cyan
    Write-Host '各步骤可输入 Q 取消；不会覆盖已有成品。请使用管理员 Windows PowerShell 5.1。'
    $hostInfo = Get-BuilderHost -AllowMissingExternalSwitch
    $hostInfo.Switches=@(Initialize-BuilderExternalSwitches -Switches $hostInfo.Switches)
    $defaultAssets = Join-Path $ProjectRoot 'data'
    if (Test-Path -LiteralPath (Join-Path $ProjectRoot 'local\settings.json')) { $defaultAssets = (Get-ProjectSettings).AssetsRoot }
    if ($AssetsRoot) { $defaultAssets = $AssetsRoot }
    $assets = Read-BuilderText -Prompt '资源目录' -Default $defaultAssets -Validate {
        param($path)
        [IO.Path]::GetFullPath($path) | Out-Null
        if (Test-Path -LiteralPath $path -PathType Leaf) { throw '资源目录不能是文件。' }
    }
    Initialize-BuilderProject -AssetsRoot $assets
    $settings = Get-ProjectSettings
    Import-Module (Join-Path $settings.UpstreamRoot 'WinImageBuilder.psm1') -Force
    while ($true) {
        $source = Read-BuilderInstallationSource -AssetsRoot $settings.AssetsRoot -SourcePath $SourcePath
        try { $images = @(Get-BuilderSourceImages -SourcePath $source); break }
        catch { Write-Host ('无法读取安装源：' + $_.Exception.Message) -ForegroundColor Yellow; $SourcePath = $null }
    }
    $preferred = 0
    for ($index=0; $index -lt $images.Count; $index++) { if ($images[$index].ImageName -eq 'Windows 11 Pro for Workstations') { $preferred = $index; break } }
    $image = Read-BuilderChoice -Prompt '选择 Windows 版本' -Items $images -DefaultIndex $preferred -Label { param($item) '{0}（索引 {1}，版本 {2}）' -f $item.ImageName,$item.ImageIndex,$item.ImageVersion }
    $keySelection=Read-BuilderProductKey -ImageName $image.ImageName
    $kmsSelection=Read-BuilderKmsServer
    $servicingIso=$source
    if([IO.Path]::GetExtension($source) -ieq '.wim'){
        $defaultIso=Find-WindowsInstallerIso -ProjectRoot $ProjectRoot -AssetsRoot $settings.AssetsRoot
        $servicingIso=Read-BuilderText -Prompt '提供匹配的 Windows 安装 ISO（用于 Windows PE 离线 servicing）' -Default $defaultIso -Validate {param($path) Assert-BuilderFile -Path $path -Extensions @('.iso')}
    }
    $defaultVirtio=Find-VirtioInstallerIso -ProjectRoot $ProjectRoot -AssetsRoot $settings.AssetsRoot
    if(-not$defaultVirtio){$defaultVirtio=Join-Path $settings.AssetsRoot 'iso\virtio-win.iso'}
    while($true){
        $virtio = Read-BuilderText -Prompt 'VirtIO ISO 路径（支持 data\iso，自动提取 guest-tools）' -Default $defaultVirtio -Validate { param($path) Assert-BuilderFile -Path $path -Extensions @('.iso') }
        try{
            Initialize-VirtioGuestTools -Settings $settings -VirtioIsoPath $virtio -RefreshFromIso|Out-Null
            Write-Host '已从 ISO 提取 virtio-win-guest-tools.exe，并确认文件名。' -ForegroundColor Green
            break
        }catch{Write-Host ('VirtIO 资源准备失败：'+$_.Exception.Message+'。请选择包含 virtio-win-guest-tools.exe 的 ISO。') -ForegroundColor Yellow;$defaultVirtio=$null}
    }
    $preferredSwitch = 0
    for ($index=0; $index -lt $hostInfo.Switches.Count; $index++) { if ($hostInfo.Switches[$index].Name -eq 'external') { $preferredSwitch = $index; break } }
    $switch = Read-BuilderChoice -Prompt '选择 Hyper-V 外部交换机' -Items $hostInfo.Switches -DefaultIndex $preferredSwitch -Label { param($item) $item.Name }
    $defaultOutput = Join-Path $settings.AssetsRoot ('output\' + (Get-DefaultImageFileName -ImageName $image.ImageName))
    $output = Read-BuilderText -Prompt '新的 QCOW2 输出路径' -Default $defaultOutput -Validate { param($path) Assert-BuilderOutput -Path $path }
    $cpu = Read-BuilderNumber -Prompt 'CPU 核数' -Default ([Math]::Min(4,$hostInfo.LogicalProcessors)) -Minimum 1 -Maximum $hostInfo.LogicalProcessors
    $maxRam = [Math]::Max(2,[Math]::Floor($hostInfo.MemoryGiB*0.75))
    $ram = Read-BuilderNumber -Prompt '内存 GiB' -Default ([Math]::Min(8,$maxRam)) -Minimum 2 -Maximum $maxRam
    $disk = Read-BuilderNumber -Prompt '系统盘 GiB' -Default 128 -Minimum 64 -Maximum 65536
    while ($true) {
        try { Assert-BuilderDiskSpace -OutputPath $output -DiskGiB $disk; break }
        catch { Write-Host $_.Exception.Message -ForegroundColor Yellow; $output = Read-BuilderText -Prompt '空间足够的新的输出路径' -Validate { param($path) Assert-BuilderOutput -Path $path } }
    }
    Write-Host '查看全部 Windows 时区（PowerShell）：Get-TimeZone -ListAvailable | Format-Table Id, DisplayName -AutoSize'
    Write-Host '填写列表中的 Id 列，例如纽约时间：Eastern Standard Time（自动处理夏令时）；也可运行 tzutil /l 查看。'
    $timeZone = Read-BuilderText -Prompt 'Windows 时区 ID' -Default 'Eastern Standard Time' -Validate { param($id) [TimeZoneInfo]::FindSystemTimeZoneById($id) | Out-Null }
    $updates = Read-BuilderBoolean -Prompt '安装 Windows Update（会增加构建时间）' -Default $false
    $chrome = Read-BuilderBoolean -Prompt '安装 Chrome' -Default $true
    $vscode = Read-BuilderBoolean -Prompt '安装 VS Code' -Default $true
    Initialize-BuilderPackages -Settings $settings -VirtioIsoPath $virtio -SkipChrome:(-not $chrome) -SkipVSCode:(-not $vscode)
    Write-Host ''
    Write-Host '配置摘要' -ForegroundColor Cyan
    [PSCustomObject]@{安装源=$source;Windows版本=$image.ImageName;产品密钥=$keySelection.Description;KMS地址=$kmsSelection.Description;输出=$output;外部交换机=$switch.Name;CPU=$cpu;内存GiB=$ram;系统盘GiB=$disk;时区=$timeZone;WindowsUpdate=$updates;Chrome=$chrome;VSCode=$vscode} | Format-List | Out-Host
    Write-Host 'UEFI / Secure Boot；VirtIO、QGA、Cloudbase-Init 必装。'
    Write-Host '内置 Administrator，PVE 注入密码后禁用额外 Admin；临时构建密码自动生成且不显示。'
    Write-Host 'RDP 开启且保留 NLA；客户机三类防火墙关闭；Defender 设置不改动。'
    $action = '仅保存配置'
    if (-not $ConfigureOnly) { $action = Read-BuilderChoice -Prompt '下一步' -Items @('开始构建','预检','仅保存配置') }
    if ($action -ne '仅保存配置') { Initialize-BuilderTools -Settings $settings }
    $configurationId=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
    $configurationPath=Join-Path $ProjectRoot ('local\configs\image-'+$configurationId+'.ini')
    $parameters = @{WimPath=$source;ServicingIsoPath=$servicingIso;ImageName=$image.ImageName;OutputPath=$output;VirtioIsoPath=$virtio;SwitchName=$switch.Name;CpuCount=$cpu;RamGiB=$ram;DiskGiB=$disk;TimeZone=$timeZone;InstallUpdates=$updates;SkipChrome=(-not $chrome);SkipVSCode=(-not $vscode);ConfigPath=$configurationPath;ProductKey=$keySelection.Key;ProductKeyMode=$keySelection.Mode;KmsServer=$kmsSelection.Address}
    $result = New-BuilderConfiguration -Parameters $parameters
    Write-Host ('已生成配置：' + $result.ConfigPath) -ForegroundColor Green
    if ($action -ne '仅保存配置') { Invoke-BuilderAction -Action $action -ConfigPath $result.ConfigPath | Out-Host }
    $result | Add-Member -NotePropertyName Action -NotePropertyValue $action -PassThru
}
