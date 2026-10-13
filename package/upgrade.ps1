param([switch]$CheckOnly, [string]$LibreOfficePath = (Join-Path $env:ProgramFiles 'LibreOffice'),
      [scriptblock]$OnProgress = { param($Percent, $Message) },
      [scriptblock]$OnCheck = { param($Result) Write-Host "[$($Result.State)] $($Result.Title)：$($Result.Message)" })
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'LibreOfficePlus\upgrades'
$pendingFile = Join-Path $root 'pending.json'
$moduleIds = @{ swriter='Writer'; scalc='Calc'; sdraw='Draw'; simpress='Impress' }
$base = Join-Path $env:APPDATA 'LibreOffice'

function Read-Application {
    $exe = Join-Path $LibreOfficePath 'program\soffice.exe'
    $version = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
    $lines = @(Get-Content -LiteralPath (Join-Path $LibreOfficePath 'program\version.ini') -Encoding UTF8 | Where-Object { $_ -cmatch '^buildid=[0-9a-f]{40}$' })
    if ($version -cnotmatch '^\d+\.\d+\.\d+\.\d+$' -or $lines.Count -ne 1) { throw '无法准确识别已安装软件的版本和构建，未开始升级。' }
    $stream = [IO.File]::OpenRead($exe)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5a4d) { throw '程序格式不正确。' }
        $stream.Position=0x3c; $offset=$reader.ReadUInt32(); $stream.Position=$offset
        if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664) { throw '兼容升级仅支持 Windows x86-64 安装。' }
    } finally { $reader.Dispose(); $stream.Dispose() }
    [pscustomobject]@{ Version=$version; BuildId=$lines[0].Substring(8) }
}
function Require-Closed {
    if (Get-Process -Name 'soffice','soffice.bin','updater' -ErrorAction SilentlyContinue) { throw '请保存文档并完全退出 LibreOffice 及其更新程序，再运行兼容升级。不会强制结束进程。' }
}
function Report($title, $message) { & $OnCheck @{Title=$title;State='通过';Message=$message} }
function Save-Pending($record) {
    $temporary = "$pendingFile.tmp"
    $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $pendingFile -Force
}
function Verify-Installer($file, $target) {
    if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -cne $target.SHA256) { throw '安装包校验值不匹配，请移除缓存中的该文件后重试。未启动安装。' }
    $signature = Get-AuthenticodeSignature -LiteralPath $file
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)(?:CN|O)=The Document Foundation(?:,|$)') { throw '安装包的官方数字签名验证失败，未启动安装。请检查系统时间和证书信任。' }
}

$upgradeMutex=$null; $lockAcquired=$false
try {
    if (!$CheckOnly) {
        $upgradeMutex=[Threading.Mutex]::new($false,('Local\LibreOfficePlus-Installer-' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value))
        try { $lockAcquired=$upgradeMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $lockAcquired=$true }
        if (!$lockAcquired) { throw '另一个配置或升级窗口正在操作，请等待它完成。' }
    }
    & $OnProgress 5 '正在读取兼容清单与当前软件版本…'
    if (![Environment]::Is64BitOperatingSystem) { throw '兼容升级仅支持 64 位 Windows。' }
    $profiles = ConvertFrom-Json -InputObject (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'compatibility.json') -Raw -Encoding UTF8)
    $targets = ConvertFrom-Json -InputObject (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'upgrade-targets.json') -Raw -Encoding UTF8)
    foreach ($target in $targets) {
        $url = [uri]$target.Url
        if ($target.Version -cnotmatch '^\d+\.\d+\.\d+\.\d+$' -or $target.BuildId -cnotmatch '^[0-9a-f]{40}$' -or
            $target.SHA256 -cnotmatch '^[0-9a-f]{64}$' -or $url.Scheme -cne 'https' -or $url.Host -cne 'downloadarchive.documentfoundation.org' -or
            $url.AbsolutePath -cne "/libreoffice/old/$($target.Version)/win/x86_64/LibreOffice_$($target.Version)_Win_x86-64.msi" -or $url.Query -or $url.Fragment -or $url.UserInfo -or !$url.IsDefaultPort -or
            @($profiles | Where-Object { $_.Version -ceq $target.Version -and $_.BuildId -ceq $target.BuildId }).Count -ne 1) { throw '升级清单与本包兼容版本不一致，未开始升级。' }
    }
    if (!$targets.Count -or @($targets.Version | Select-Object -Unique).Count -ne $targets.Count) { throw '升级清单为空或含重复版本。' }
    $current = Read-Application
    if (@($profiles | Where-Object { $_.Version -ceq $current.Version -and $_.BuildId -ceq $current.BuildId }).Count -ne 1) { throw "当前 $($current.Version) 的构建未适配，请先获取对应配置包；不会自动降级或覆盖。" }
    $stateFile = Join-Path $base 'wps-ui-files-backup\state.json'
    $files = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8)
    if (!$files.Count -or @($files | Where-Object { !$moduleIds.ContainsKey($_.Module) }).Count) { throw '没有有效的模块安装记录，请先运行本版 安装.vbs。' }
    $modules = @($files.Module | Select-Object -Unique | ForEach-Object { $moduleIds[$_] })
    $pending = $null
    if (Test-Path -LiteralPath $pendingFile) {
        $pending = Get-Content -LiteralPath $pendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($pending.Owner -cne 'LibreOfficePlus' -or $pending.Id -cnotmatch '^[0-9a-f]{32}$' -or
            $pending.ApplicationPath -cne [IO.Path]::GetFullPath($LibreOfficePath) -or
            @($pending.Modules | Where-Object { $_ -notin $moduleIds.Values }).Count -or !$pending.Modules.Count -or
            (Compare-Object @($pending.Modules) @($modules)) -or
            @($targets | Where-Object { $_.Version -ceq $pending.TargetVersion -and $_.BuildId -ceq $pending.TargetBuildId }).Count -ne 1 -or
            ($current.BuildId -cne $pending.FromBuildId -and $current.BuildId -cne $pending.TargetBuildId)) { throw '存在无法匹配的未完成升级记录，请保留缓存和备份，不会覆盖该记录。' }
        $target = $targets | Where-Object { $_.BuildId -ceq $pending.TargetBuildId }
        $modules = @($pending.Modules)
    } else {
        $target = $targets | Where-Object { [version]$_.Version -gt [version]$current.Version } | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
    }
    $plan = [pscustomobject]@{ Current=$current; Target=$target; Modules=$modules; Resuming=[bool]$pending; CacheRoot=$root }
    if ($CheckOnly) { return $plan }
    Report '版本兼容' "当前 $($current.Version)；只接受本包已适配的完整版本与构建。"
    if (!$target) { Report '升级结果' '当前已是本包支持的最新版本。更多版本请先获取新版 LibreOfficePlus。'; & $OnProgress 100 '无需升级。'; return }
    Require-Closed
    Report '运行状态' '软件与更新进程已退出。'
    $profile = Join-Path $base '4\user'
    $config = Join-Path $profile 'registrymodifications.xcu'
    if (!(Test-Path -LiteralPath $config -PathType Leaf)) { throw '用户配置缺失，请先运行本版安装入口。' }
    $cache = Join-Path $root ("cache\" + $target.BuildId)
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    $msi = Join-Path $cache 'installer.msi'
    & $OnProgress 20 "正在缓存已适配版本 $($target.Version) 的官方安装包…"
    if (!(Test-Path -LiteralPath $msi)) {
        $partial = Join-Path $cache 'installer.partial.msi'
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $target.Url -OutFile $partial -UseBasicParsing -TimeoutSec 1800
            Verify-Installer $partial $target
            Move-Item -LiteralPath $partial -Destination $msi
        } finally { if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial } }
    }
    Verify-Installer $msi $target
    Report '安装包验证' '缓存已核对 SHA-256 和 The Document Foundation 数字签名，可断网复用。'
    Require-Closed
    $transaction = if ($pending) { Join-Path $root ("transactions\" + $pending.Id) } else { Join-Path $root ("transactions\" + [guid]::NewGuid().ToString('N')) }
    if (!$pending) {
        & $OnProgress 35 '正在备份升级前的界面、设置和首次恢复记录…'
        New-Item -ItemType Directory -Path $transaction | Out-Null
        Copy-Item -LiteralPath $config -Destination (Join-Path $transaction 'registrymodifications.xcu')
        foreach ($relative in '4\user\config','wps-ui-backup.xml','wps-ui-files-backup') {
            $source = Join-Path $base $relative
            if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $transaction ([IO.Path]::GetFileName($relative))) -Recurse }
        }
        $pending = [pscustomobject]@{Owner='LibreOfficePlus';Id=(Split-Path $transaction -Leaf);ApplicationPath=[IO.Path]::GetFullPath($LibreOfficePath);FromVersion=$current.Version;FromBuildId=$current.BuildId;TargetVersion=$target.Version;TargetBuildId=$target.BuildId;Modules=$modules;Status='Prepared';CompletedAt=$null}
        Save-Pending $pending
    } elseif (!(Test-Path -LiteralPath (Join-Path $transaction 'registrymodifications.xcu'))) { throw '未完成升级的备份缺失，不会继续覆盖配置。' }
    Report '升级前备份' '升级前设置与首次备份均已保留；失败后可继续运行此入口。'
    if ($current.BuildId -cne $target.BuildId) {
        # 在 MSI 执行前再次应用更新开关，避免下一次启动被官方增量更新抢先处理。
        & (Join-Path $PSScriptRoot 'configure.ps1') -Modules ($modules -join ',') -LibreOfficePath $LibreOfficePath -OnProgress { param($Percent,$Message) } -OnCheck { param($Result) } | Out-Null
        Require-Closed
        Verify-Installer $msi $target
        & $OnProgress 55 "正在安装兼容版本 $($target.Version)，可能需要 Windows 管理员授权…"
        $pending.Status='Installing'; Save-Pending $pending
        $log = Join-Path $transaction 'install.log'
        $arguments = '/i "' + $msi + '" /passive /norestart ALLUSERS=1 CREATEDESKTOPLINK=0 INSTALLLOCATION="' + [IO.Path]::GetFullPath($LibreOfficePath) + '" /L*v "' + $log + '"'
        $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru -Wait
        if ($process.ExitCode -eq 3010) { throw 'Windows 安装程序要求重启。请重启电脑后再次运行 兼容升级.vbs，以完成构建核验和界面配置。备份与进度已保留。' }
        if ($process.ExitCode -ne 0) { throw "安装未完成（Windows Installer：$($process.ExitCode)）。请查看 $log；备份与缓存已保留，未宣告升级成功。" }
    }
    & $OnProgress 80 '正在核对安装后的完整版本、构建并重新配置原有模块…'
    $installed = Read-Application
    if ($installed.Version -cne $target.Version -or $installed.BuildId -cne $target.BuildId) { throw '安装后的版本或构建不匹配，未应用新版界面。请保留备份并检查安装结果。' }
    Require-Closed
    $pending.Status='Configuring'; Save-Pending $pending
    $upgradeProgress = $OnProgress
    & (Join-Path $PSScriptRoot 'configure.ps1') -Modules ($modules -join ',') -LibreOfficePath $LibreOfficePath -OnProgress {
        param($Percent,$Message) & $upgradeProgress (80 + [int]($Percent * 0.15)) $Message
    } -OnCheck { param($Result) } | Out-Null
    Report '升级结果' "已升级到 $($installed.Version)，并重新配置 $($modules -join '、')。官方自动更新继续关闭。"
    $pending.Status='Completed'; $pending.CompletedAt=[DateTime]::UtcNow.ToString('o')
    $pending | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $transaction 'record.json') -Encoding UTF8
    Remove-Item -LiteralPath $pendingFile
    # 只清理本助手标记为完成的旧快照；失败、未知文件及首次备份不参与。
    try {
        $completed = @(Get-ChildItem -LiteralPath (Join-Path $root 'transactions') -Directory | Where-Object { $_.Name -cmatch '^[0-9a-f]{32}$' -and !($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } | ForEach-Object {
            $recordPath=Join-Path $_.FullName 'record.json'
            if (Test-Path -LiteralPath $recordPath) {
                $record=Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($record.Owner -ceq 'LibreOfficePlus' -and $record.Status -ceq 'Completed' -and $record.Id -ceq $_.Name) { [pscustomobject]@{Path=$_.FullName;CompletedAt=$record.CompletedAt} }
            }
        })
        foreach ($old in ($completed | Sort-Object CompletedAt -Descending | Select-Object -Skip 2)) {
            $resolved=[IO.Path]::GetFullPath($old.Path)
            if ([IO.Path]::GetDirectoryName($resolved) -cne [IO.Path]::GetFullPath((Join-Path $root 'transactions'))) { throw '旧备份路径不正确，未清理。' }
            if (!(Get-ChildItem -LiteralPath $resolved -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })) { Remove-Item -LiteralPath $resolved -Recurse }
        }
    } catch { & $OnCheck @{Title='备份整理';State='提示';Message='升级已完成，但旧快照暂未清理：' + $_.Exception.Message} }
    & $OnProgress 100 '兼容升级完成，现在可以打开 LibreOffice。'
} catch {
    if ($CheckOnly) { throw }
    & $OnCheck @{Title='升级结果';State='需处理';Message=$_.Exception.Message}
    throw
} finally {
    if ($lockAcquired) { $upgradeMutex.ReleaseMutex() }
    if ($upgradeMutex) { $upgradeMutex.Dispose() }
}
