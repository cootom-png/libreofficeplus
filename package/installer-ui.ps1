param([switch]$Restore, [switch]$Upgrade, [string]$Modules = 'Writer,Calc,Draw,Impress',
      [string]$LibreOfficePath = (Join-Path $env:ProgramFiles 'LibreOffice'))
$ErrorActionPreference = 'Stop'
try {
    Add-Type -AssemblyName PresentationFramework
    [xml]$layout = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'installer.xaml') -Raw -Encoding UTF8
    $window = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($layout))
    $version = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'version.json') -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    # 即使界面初始化失败，也在可见对话框中说明原因。
    $shell = New-Object -ComObject WScript.Shell
    $shell.Popup("无法打开配置窗口：$($_.Exception.Message)",0,'LibreOfficePlus',16) | Out-Null
    exit 1
}
$controls = @{}
foreach ($name in 'Heading','Subtitle','StatusTitle','Percent','Progress','ProgressPanel','StatusMessage','Step1','Step2','Step3','Checks','Details','Footer','CloseButton','VersionLabel','SelectionPanel','ModuleWriter','ModuleCalc','ModuleDraw','ModuleImpress','ApplicationPath','FontNotice','TemplatesButton','StartButton','ModuleHeading','UpgradeButton','PackageButton') {
    $controls[$name] = $window.FindName($name)
}
$operation = if ($Upgrade) { '升级' } elseif ($Restore) { '恢复' } else { '安装' }
$window.Title = "LibreOfficePlus · $operation"
$window.MaxHeight = [Windows.SystemParameters]::WorkArea.Height
$window.Height = [Math]::Min($window.Height,$window.MaxHeight)
$controls.VersionLabel.Text = 'v' + $version.Version
$controls.ApplicationPath.Text = $LibreOfficePath
foreach ($module in 'Writer','Calc','Draw','Impress') { $controls["Module$module"].IsChecked = $Modules.Split(',').Trim() -contains $module }
$hasFont = @([Windows.Media.Fonts]::SystemFontFamilies | Where-Object { $_.Source -in @('SimSun','宋体') }).Count -gt 0
$controls.FontNotice.Text = if ($hasFont) { '模板字体：宋体已安装。' } else { '模板字体：未检测到宋体，打开模板时可能使用替代字体。本包不附带字体。' }
if ($Restore) {
    $controls.Heading.Text = '恢复原界面，保留你的习惯'
    $controls.Subtitle.Text = '从首次备份还原所选模块的界面与设置'
    $controls.ApplicationPath.IsEnabled = $false
    $controls.FontNotice.Text = '恢复用户配置无需匹配软件版本或模板字体。'
    $controls.StartButton.Content = '开始恢复'
    $controls.StatusMessage.Text = '选择模块后点击“开始恢复”，检查结果会逐项显示。'
}
if ($Upgrade) {
    $controls.Heading.Text = '兼容确认后，再升级'
    $controls.Subtitle.Text = '缓存官方安装包 · 保留备份 · 自动重新配置原有模块'
    foreach ($module in 'Writer','Calc','Draw','Impress') { $controls["Module$module"].Visibility='Collapsed' }
    $controls.ModuleHeading.Text = '自动沿用原有模块，无需重新选择'
    $controls.FontNotice.Text = '仅升级到本包已适配的版本。下载会核对官方安装包的校验值和数字签名。'
    $controls.StartButton.Content = '检查并开始升级'
    $controls.StatusMessage.Text = '保存文档并退出软件后开始。已缓存的合格安装包可断网复用；Windows 可能要求管理员授权。'
    $controls.Step1.Text = '01  兼容与缓存'
    $controls.Step2.Text = '02  备份与升级'
    $controls.Step3.Text = '03  核验与配置'
}
$controls.StatusTitle.Text = "准备$operation"
$controls.Details.Text = if ($Restore) { '先保存文档并退出软件；将还原所选模块的首次备份。' } else { '保留熟悉的功能区与快捷键，应用 Material 浅色外观。自动核对软件版本和首次备份；未适配版本会停止。' }
if ($Upgrade) { $controls.Details.Text = '升级不会强制关闭文档，不会自动降级。失败或要求重启时保留缓存与备份，再次运行本入口继续；不自动回滚软件本体。' }
if ($Upgrade -or $Restore) { $controls.UpgradeButton.Visibility='Collapsed' }
$state = [hashtable]::Synchronized(@{ Update=@{ Percent=0; Message='正在启动配置程序…' }; Checks=@(); Failure=$null; Finished=$false })
$checkTitles = @('运行环境','安装目录','版本兼容','运行状态','用户配置','目录写入','配置包文件','首次备份')
if ($Upgrade) { $checkTitles=@('版本兼容','运行状态','安装包验证','升级前备份','升级结果') }
function Refresh-Checks {
    $snapshot = @($state.Checks)
    $titles = @($checkTitles) + @($snapshot | Where-Object { $_.Title -notin $checkTitles } | ForEach-Object { $_.Title } | Select-Object -Unique)
    $controls.Checks.ItemsSource = @(foreach ($title in $titles) {
        $result = $snapshot | Where-Object { $_.Title -eq $title } | Select-Object -Last 1
        $status = if ($result) { $result.State } elseif ($state.Finished -and !$state.Failure) { '不适用' } else { '未检查' }
        [pscustomobject]@{
            Title=$title; State=$status; Message=$(if ($result) { $result.Message } elseif ($state.Failure) { '前置检查未通过，本次未执行。' } elseif ($state.Finished) { '本次无需执行。' } else { '等待前面的检查完成。' })
            Color=$(switch ($status) { '通过' { '#146C2E' }; '需处理' { '#B3261E' }; default { '#444746' } })
        }
    })
}
Refresh-Checks
$job = [PowerShell]::Create()
$worker = {
    param($CorePath, $State, $RestoreMode, $SelectedModules, $ApplicationPath)
    $mutex = [Threading.Mutex]::new($false,('Local\LibreOfficePlus-Installer-' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value))
    $acquired = $false
    try {
        if ((Split-Path $CorePath -Leaf) -eq 'configure.ps1') {
            try { $acquired = $mutex.WaitOne(0) }
            catch [Threading.AbandonedMutexException] { $acquired = $true }
            if (!$acquired) { throw '另一个配置窗口正在操作，请等待它完成后再试。' }
        }
        $arguments = @{ LibreOfficePath=$ApplicationPath; OnProgress={
            param($Percent, $Message)
            $State.Update = @{ Percent=$Percent; Message=$Message }
        }; OnCheck={
            param($Result)
            $State.Checks = @($State.Checks) + @($Result)
        } }
        if ((Split-Path $CorePath -Leaf) -eq 'configure.ps1') { $arguments.Restore=$RestoreMode; $arguments.Modules=$SelectedModules }
        & $CorePath @arguments | Out-Null
    } catch { $State.Failure = $_.Exception.Message }
    finally { if ($acquired) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}
$ui = @{ Running=$false; Handle=$null; ExitCode=1; CheckCount=0; Modules=$Modules }
$timer = [Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(80)
$timer.Add_Tick({
    $update = $state.Update
    $controls.Progress.Value = $update.Percent
    $controls.Percent.Text = "$($update.Percent)%"
    $controls.StatusMessage.Text = $update.Message
    $controls.StatusTitle.Text = "正在$operation"
    if ($ui.CheckCount -ne $state.Checks.Count) { Refresh-Checks; $ui.CheckCount=$state.Checks.Count }
    $stage = if ($update.Percent -lt 30) { 1 } elseif ($update.Percent -lt 95) { 2 } else { 3 }
    foreach ($number in 1..3) {
        $controls["Step$number"].Foreground = if ($number -le $stage) { '#0B57D0' } else { '#747775' }
    }
    if (!$ui.Handle.IsCompleted) { return }
    $timer.Stop()
    try { $job.EndInvoke($ui.Handle) | Out-Null }
    catch { if (!$state.Failure) { $state.Failure = $_.Exception.Message } }
    $job.Dispose()
    $state.Finished=$true
    Refresh-Checks
    $ui.Running = $false
    $controls.CloseButton.IsEnabled = $true
    $controls.CloseButton.Content = '完成并关闭'
    if ($state.Failure) {
        $controls.StatusTitle.Text = "未能完成$operation"
        $controls.StatusMessage.Text = '请查看检查结果及下方原因，处理后重新运行。'
        $controls.Details.Text = $state.Failure
        $controls.Progress.Foreground = '#B3261E'
        $controls.Percent.Text = '需要处理'
        $controls.Percent.Foreground = '#B3261E'
        $controls.Footer.Text = '处理问题后可重新运行；已有备份请保留'
        $controls.CloseButton.Content = '关闭'
    } else {
        $ui.ExitCode = 0
        $controls.StatusTitle.Text = "$($operation)完成"
        $controls.Progress.Value = 100
        $controls.Progress.Foreground = '#146C2E'
        $controls.Percent.Text = '100%'
        $controls.Percent.Foreground = '#146C2E'
        $controls.StatusMessage.Text = if ($Upgrade) { $state.Update.Message } else { '现在可以重新打开 LibreOffice，查看你的界面。' }
        $controls.Details.Text = if ($Restore) { "已恢复：$($ui.Modules)`n所选模块已恢复；全部恢复后还原通用外观和升级设置。" } else { "已配置：$($ui.Modules)`nMaterial 浅色外观已应用，官方自动更新已关闭。首次备份已保留，可通过兼容升级入口更新。" }
        if ($Upgrade) { $controls.Details.Text = '兼容版本与构建核验结果见上方。首次恢复备份继续保留；本包没有更高兼容版本时，请先获取新版配置包。' }
        if (!$Restore -and !$Upgrade) { $controls.TemplatesButton.Visibility = 'Visible' }
        $controls.Footer.Text = '已完成 · 可以关闭此窗口'
    }
})
$controls.CloseButton.Add_Click({ $window.Close() })
$controls.TemplatesButton.Add_Click({ Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + (Join-Path $PSScriptRoot 'templates') + '"') })
$controls.PackageButton.Add_Click({ Start-Process 'https://github.com/cootom-png/libreofficeplus/releases/latest' })
$controls.UpgradeButton.Add_Click({
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList ('-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" -Upgrade -LibreOfficePath "' + $controls.ApplicationPath.Text.Trim() + '"') -WindowStyle Hidden
    $window.Close()
})
$window.Add_Closing({ param($sender,$event) if ($ui.Running) { $event.Cancel=$true } })
$controls.StartButton.Add_Click({
    if ($ui.Handle) { return }
    $selected = @('Writer','Calc','Draw','Impress' | Where-Object { $controls["Module$_"].IsChecked })
    if (!$Upgrade -and !$selected.Count) { $controls.StatusMessage.Text = '请至少选择一个模块。'; return }
    $ui.Modules = $selected -join ','
    $coreName = if ($Upgrade) { 'upgrade.ps1' } else { 'configure.ps1' }
    $null = $job.AddScript($worker.ToString()).AddArgument((Join-Path $PSScriptRoot $coreName)).AddArgument($state).AddArgument($Restore.IsPresent).AddArgument($ui.Modules).AddArgument($controls.ApplicationPath.Text.Trim())
    $ui.Running = $true
    $controls.SelectionPanel.Visibility = 'Collapsed'
    $controls.ProgressPanel.Visibility = 'Visible'
    $controls.Checks.Visibility = 'Visible'
    $controls.StartButton.Visibility = 'Collapsed'
    $controls.CloseButton.IsEnabled = $false
    $controls.UpgradeButton.IsEnabled = $false
    $controls.CloseButton.Content = '正在配置…'
    $ui.Handle = $job.BeginInvoke()
    $timer.Start()
})
$window.Add_ContentRendered({ $controls.StartButton.Focus() | Out-Null })
try { $null = $window.ShowDialog() }
finally { $timer.Stop(); if (!$ui.Handle -or $ui.Running) { $job.Dispose() } }
exit $ui.ExitCode
