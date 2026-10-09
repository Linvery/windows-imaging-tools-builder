. (Join-Path $PSScriptRoot 'Build.Resources.ps1')
function Read-PveCleanupChoice {
    while ($true) {
        $answer=([string](Read-Host '是否清理本轮构建的临时资源？(Y/N) [Y]')).Trim()
        if (-not $answer -or $answer -in @('y','yes')) { return $true }
        if ($answer -in @('n','no')) { return $false }
        Write-Host '请输入 Y 或 N，回车默认选择是。' -ForegroundColor Yellow
    }
}
function Test-PveBuildCancellationKey {
    if ([Console]::IsInputRedirected) { return $false }
    while ([Console]::KeyAvailable) {
        $key=[Console]::ReadKey($true)
        if ([int]$key.KeyChar -eq 3 -or ($key.Key -eq [ConsoleKey]::C -and ($key.Modifiers -band [ConsoleModifiers]::Control))) { return $true }
    }
    return $false
}
function Write-PveBuildOutput {
    param([string]$Line)
    if ($Line -eq '#< CLIXML') { return }
    if ($Line.StartsWith('<Objs ') -and $Line.Contains('http://schemas.microsoft.com/powershell/2004/04')) {
        try {
            $document=[Xml.XmlDocument]::new()
            $document.XmlResolver=$null
            $document.LoadXml($Line)
            foreach ($node in $document.DocumentElement.ChildNodes) {
                if ($node.GetAttribute('S') -in @('error','warning','verbose','debug')) {
                    $value=$node.InnerText
                    $value=[regex]::Replace($value,'_x([0-9a-fA-F]{4})_',[Text.RegularExpressions.MatchEvaluator]{param($match) [string][char][Convert]::ToInt32($match.Groups[1].Value,16)})
                    Write-Host $value
                }
            }
            return
        } catch {}
    }
    Write-Host $Line
}
function Set-PveCancelledBuildState {
    param([string]$ContextPath,[string]$Cleanup,[string]$Detail)
    $context=Get-PveBuildResources -ContextPath $ContextPath
    $context.Cleanup=$Cleanup
    Save-PveBuildResources -ContextPath $ContextPath -Context $context
    $path=Join-Path $context.LogDirectory 'status.json'
    $state=[ordered]@{Phase='cancelled';OutputPath=$context.OutputPath;LogDirectory=$context.LogDirectory;Cleanup=$Cleanup;CancelledUtc=[DateTime]::UtcNow.ToString('o')}
    if ($Detail) { $state.Error=$Detail }
    [IO.File]::WriteAllText($path,($state|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    return [PSCustomObject]$state
}
function Invoke-PveCancelledBuild {
    param([string]$ContextPath)
    try { Stop-PveOwnedBuildVms -ContextPath $ContextPath }
    catch { Write-Host ('停止本轮临时 VM 时遇到问题：'+$_.Exception.Message) -ForegroundColor Yellow }
    if (Read-PveCleanupChoice) {
        try {
            Remove-PveOwnedBuildResources -ContextPath $ContextPath
            Write-Host '构建已取消，本轮临时资源已清理。ISO、安装包和日志已保留。' -ForegroundColor Green
            return Set-PveCancelledBuildState -ContextPath $ContextPath -Cleanup 'complete'
        } catch {
            Write-Host ('构建已取消，部分资源未能清理：'+$_.Exception.Message) -ForegroundColor Yellow
            return Set-PveCancelledBuildState -ContextPath $ContextPath -Cleanup 'failed' -Detail $_.Exception.Message
        }
    }
    Write-Host '构建已取消，临时资源已保留。' -ForegroundColor Yellow
    return Set-PveCancelledBuildState -ContextPath $ContextPath -Cleanup 'declined'
}
function Invoke-PveControlledBuild {
    param([string]$ScriptPath,[string]$ConfigPath,$Settings,$Config,[string]$ServicingIsoPath,[switch]$SkipBootVerification)
    if (-not ('PveImageBuilder.BuildProcess' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'Build.Process.cs') }
    $outputLock=$null
    try {
    $lockDirectory=Join-Path $Settings.ProjectRoot 'local\build-locks'
    New-Item -ItemType Directory -Path $lockDirectory -Force | Out-Null
    $hasher=[Security.Cryptography.SHA256]::Create()
    try { $lockName=([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Config.image_path).ToLowerInvariant())))).Replace('-','')+'.lock' }
    finally { $hasher.Dispose() }
    try { $outputLock=[IO.File]::Open((Join-Path $lockDirectory $lockName),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch { throw '另一个构建正在使用同一输出路径，请选择新的输出文件名。' }
    $runId=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N')
    $logDirectory=Join-Path $Settings.AssetsRoot ('logs\builds\wizard-'+$runId)
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    $contextPath=Join-Path $logDirectory 'resources.json'
    $context=[PSCustomObject]@{SchemaVersion=1;RunId=$runId;AssetsRoot=[IO.Path]::GetFullPath($Settings.AssetsRoot);OutputPath=[IO.Path]::GetFullPath($Config.image_path);LogDirectory=[IO.Path]::GetFullPath($logDirectory);Completed=$false;Cleanup='not_requested';Files=@();Directories=@();VMs=@();SourceIsos=@()}
    foreach ($iso in @($Config.wim_file_path,$Config.virtio_iso_path,$ServicingIsoPath) | Select-Object -Unique) {
        if ([IO.Path]::GetExtension($iso) -ieq '.iso') {
            $image=Get-DiskImage -ImagePath $iso -ErrorAction Stop
            $context.SourceIsos+= [PSCustomObject]@{Path=[IO.Path]::GetFullPath($iso);AttachedBefore=[bool]$image.Attached}
        }
    }
    Save-PveBuildResources -ContextPath $contextPath -Context $context
    Register-PveBuildFile -ContextPath $contextPath -Path $context.OutputPath
    Register-PveBuildFile -ContextPath $contextPath -Path ([IO.Path]::ChangeExtension($context.OutputPath,'.vhdx')) -Kind Disk
    Register-PveBuildFile -ContextPath $contextPath -Path ([IO.Path]::ChangeExtension($context.OutputPath,'.raw')) -Kind Disk
    $quote={param($value) "'"+$value.Replace("'","''")+"'"}
    $snapshot=Join-Path $logDirectory 'build.ini'
    Register-PveBuildFile -ContextPath $contextPath -Path $snapshot
    Register-PveBuildFile -ContextPath $contextPath -Path ($snapshot+'.offline')
    Copy-Item -LiteralPath ([IO.Path]::GetFullPath($ConfigPath)) -Destination $snapshot
    $command='[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $ProgressPreference=''SilentlyContinue''; try { & '+(& $quote $ScriptPath)+' -ConfigPath '+(& $quote $snapshot)+' -InternalWorker -ResourceContextPath '+(& $quote $contextPath)+' -Confirm:$false'
    if ($SkipBootVerification) { $command+=' -SkipBootVerification' }
    $command+=' } catch { [Console]::Error.WriteLine($_.ToString()); exit 1 }; if ($?) { exit 0 } else { exit 1 }'
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $worker=$null
    $consoleChanged=$false
    $previous=$false
    $cancelled=$false
    try {
        if (-not [Console]::IsInputRedirected) {
            $previous=[Console]::TreatControlCAsInput
            [Console]::TreatControlCAsInput=$true
            $consoleChanged=$true
        }
        $worker=[PveImageBuilder.BuildProcess]::new((Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'),('-NoProfile -ExecutionPolicy Bypass -OutputFormat Text -EncodedCommand '+$encoded),(Split-Path -Parent $ScriptPath))
        Write-Host '构建已启动。按 Ctrl+C 中断后，可选择是否清理本轮临时资源（默认是）。' -ForegroundColor Cyan
        while (-not $worker.HasExited) {
            foreach ($line in $worker.ReadOutput()) { Write-PveBuildOutput -Line $line }
            if (Test-PveBuildCancellationKey) { $cancelled=$true; $worker.Cancel(); break }
            Start-Sleep -Milliseconds 150
        }
        $worker.Wait()
        foreach ($line in $worker.ReadOutput()) { Write-PveBuildOutput -Line $line }
        $exitCode=$worker.ExitCode
    } finally {
        if ($consoleChanged) { [Console]::TreatControlCAsInput=$previous }
        if ($worker) { $worker.Dispose() }
    }
    if ($cancelled) {
        $latest=Get-PveBuildResources -ContextPath $contextPath
        if (-not $latest.Completed) { return Invoke-PveCancelledBuild -ContextPath $contextPath }
    }
    if ($exitCode -ne 0 -and -not $cancelled) { throw ('构建失败，日志：'+$logDirectory) }
    return Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $logDirectory 'status.json') | ConvertFrom-Json
    } finally { if ($outputLock) { $outputLock.Dispose() } }
}
