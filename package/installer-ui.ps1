param([switch]$Restore, [string]$Modules = 'Writer,Calc,Draw,Impress',
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
foreach ($name in 'Heading','Subtitle','StatusTitle','Percent','Progress','StatusMessage','Step1','Step2','Step3','Checks','Details','Footer','CloseButton','VersionLabel','SelectionPanel','ModuleWriter','ModuleCalc','ModuleDraw','ModuleImpress','ApplicationPath','FontNotice','TemplatesButton','StartButton') {
    $controls[$name] = $window.FindName($name)
}
$operation = if ($Restore) { '恢复' } else { '安装' }
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
$controls.StatusTitle.Text = "准备$operation"
$controls.Details.Text = if ($Restore) { '先保存文档并退出软件；将还原所选模块的首次备份。' } else { '自动识别 LibreOffice 版本并选择专属界面。先保存文档并退出软件；未适配的版本会阻止安装。' }
$state = [hashtable]::Synchronized(@{ Update=@{ Percent=0; Message='正在启动配置程序…' }; Checks=@(); Failure=$null })
$checkTitles = @('运行环境','安装目录','版本兼容','运行状态','用户配置','目录写入','配置包文件','首次备份')
function Refresh-Checks {
    $snapshot = @($state.Checks)
    $titles = @($checkTitles) + @($snapshot | Where-Object { $_.Title -notin $checkTitles } | ForEach-Object { $_.Title } | Select-Object -Unique)
    $controls.Checks.ItemsSource = @(foreach ($title in $titles) {
        $result = $snapshot | Where-Object { $_.Title -eq $title } | Select-Object -Last 1
        $status = if ($result) { $result.State } else { '未检查' }
        [pscustomobject]@{
            Title=$title; State=$status; Message=$(if ($result) { $result.Message } elseif ($state.Failure) { '前置检查未通过，本次未执行。' } else { '等待前面的检查完成。' })
            Color=$(switch ($status) { '通过' { '#128562' }; '需处理' { '#C83939' }; default { '#8795A9' } })
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
        try { $acquired = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (!$acquired) { throw '另一个配置窗口正在操作，请等待它完成后再试。' }
        & $CorePath -Restore:$RestoreMode -Modules $SelectedModules -LibreOfficePath $ApplicationPath -OnProgress {
            param($Percent, $Message)
            $State.Update = @{ Percent=$Percent; Message=$Message }
        } -OnCheck {
            param($Result)
            $State.Checks = @($State.Checks) + @($Result)
        } | Out-Null
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
        $controls["Step$number"].Foreground = if ($number -le $stage) { '#2563EB' } else { '#8795A9' }
    }
    if (!$ui.Handle.IsCompleted) { return }
    $timer.Stop()
    try { $job.EndInvoke($ui.Handle) | Out-Null }
    catch { if (!$state.Failure) { $state.Failure = $_.Exception.Message } }
    $job.Dispose()
    Refresh-Checks
    $ui.Running = $false
    $controls.CloseButton.IsEnabled = $true
    $controls.CloseButton.Content = '完成并关闭'
    if ($state.Failure) {
        $controls.StatusTitle.Text = "未能完成$operation"
        $controls.StatusMessage.Text = '请查看检查结果及下方原因，处理后重新运行。'
        $controls.Details.Text = $state.Failure
        $controls.Progress.Foreground = '#DC4C4C'
        $controls.Percent.Text = '需要处理'
        $controls.Percent.Foreground = '#DC4C4C'
        $controls.Footer.Text = '处理问题后可重新运行；已有备份请保留'
        $controls.CloseButton.Content = '关闭'
    } else {
        $ui.ExitCode = 0
        $controls.StatusTitle.Text = "$($operation)完成"
        $controls.Progress.Value = 100
        $controls.Progress.Foreground = '#12A47B'
        $controls.Percent.Text = '100%'
        $controls.Percent.Foreground = '#12A47B'
        $controls.StatusMessage.Text = '现在可以重新打开 LibreOffice，查看你的界面。'
        $controls.Details.Text = if ($Restore) { "已恢复：$($ui.Modules)`n所选模块已还原到首次安装前的设置。" } else { "已配置：$($ui.Modules)`n首次备份已保留，双击 恢复原界面.vbs 即可恢复。" }
        if (!$Restore) { $controls.TemplatesButton.Visibility = 'Visible' }
        $controls.Footer.Text = '已完成 · 可以关闭此窗口'
    }
})
$controls.CloseButton.Add_Click({ $window.Close() })
$controls.TemplatesButton.Add_Click({ Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + (Join-Path $PSScriptRoot 'templates') + '"') })
$window.Add_Closing({ param($sender,$event) if ($ui.Running) { $event.Cancel=$true } })
$controls.StartButton.Add_Click({
    if ($ui.Handle) { return }
    $selected = @('Writer','Calc','Draw','Impress' | Where-Object { $controls["Module$_"].IsChecked })
    if (!$selected.Count) { $controls.StatusMessage.Text = '请至少选择一个模块。'; return }
    $ui.Modules = $selected -join ','
    $null = $job.AddScript($worker.ToString()).AddArgument((Join-Path $PSScriptRoot 'configure.ps1')).AddArgument($state).AddArgument($Restore.IsPresent).AddArgument($ui.Modules).AddArgument($controls.ApplicationPath.Text.Trim())
    $ui.Running = $true
    $controls.SelectionPanel.Visibility = 'Collapsed'
    $controls.StartButton.Visibility = 'Collapsed'
    $controls.CloseButton.IsEnabled = $false
    $controls.CloseButton.Content = '正在配置…'
    $ui.Handle = $job.BeginInvoke()
    $timer.Start()
})
$window.Add_ContentRendered({ $controls.StartButton.Focus() | Out-Null })
try { $null = $window.ShowDialog() }
finally { $timer.Stop(); if (!$ui.Handle -or $ui.Running) { $job.Dispose() } }
exit $ui.ExitCode
