param([switch]$Restore, [string]$Modules = 'Writer,Calc,Draw',
      [string]$LibreOfficePath = (Join-Path $env:ProgramFiles 'LibreOffice'))
$ErrorActionPreference = 'Stop'
try {
    Add-Type -AssemblyName PresentationFramework
    [xml]$layout = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'installer.xaml') -Raw -Encoding UTF8
    $window = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($layout))
} catch {
    # 即使界面初始化失败，也在可见对话框中说明原因。
    $shell = New-Object -ComObject WScript.Shell
    $shell.Popup("无法打开配置窗口：$($_.Exception.Message)",0,'LibreOfficePlus',16) | Out-Null
    exit 1
}
$controls = @{}
foreach ($name in 'Heading','Subtitle','StatusTitle','Percent','Progress','StatusMessage','Step1','Step2','Step3','Details','Footer','CloseButton') {
    $controls[$name] = $window.FindName($name)
}
$operation = if ($Restore) { '恢复' } else { '安装' }
$window.Title = "LibreOfficePlus · $operation"
if ($Restore) {
    $controls.Heading.Text = '恢复原界面，保留你的习惯'
    $controls.Subtitle.Text = '从首次备份还原所选模块的界面与设置'
}
$controls.StatusTitle.Text = "正在准备$operation"
$controls.Details.Text = "所选模块：$Modules`n请等待操作完成，再打开 LibreOffice。"
$state = [hashtable]::Synchronized(@{ Update=@{ Percent=0; Message='正在启动配置程序…' }; Failure=$null })
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
        } | Out-Null
    } catch { $State.Failure = $_.Exception.Message }
    finally { if ($acquired) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}
$null = $job.AddScript($worker.ToString()).AddArgument((Join-Path $PSScriptRoot 'configure.ps1')).AddArgument($state).AddArgument($Restore.IsPresent).AddArgument($Modules).AddArgument($LibreOfficePath)
$ui = @{ Running=$true; Handle=$null; ExitCode=1 }
$timer = [Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(80)
$timer.Add_Tick({
    $update = $state.Update
    $controls.Progress.Value = $update.Percent
    $controls.Percent.Text = "$($update.Percent)%"
    $controls.StatusMessage.Text = $update.Message
    $controls.StatusTitle.Text = "正在$operation"
    $stage = if ($update.Percent -lt 30) { 1 } elseif ($update.Percent -lt 95) { 2 } else { 3 }
    foreach ($number in 1..3) {
        $controls["Step$number"].Foreground = if ($number -le $stage) { '#2563EB' } else { '#8795A9' }
    }
    if (!$ui.Handle.IsCompleted) { return }
    $timer.Stop()
    try { $job.EndInvoke($ui.Handle) | Out-Null }
    catch { if (!$state.Failure) { $state.Failure = $_.Exception.Message } }
    $job.Dispose()
    $ui.Running = $false
    $controls.CloseButton.IsEnabled = $true
    $controls.CloseButton.Content = '完成并关闭'
    if ($state.Failure) {
        $controls.StatusTitle.Text = "未能完成$operation"
        $controls.StatusMessage.Text = '请按下方提示处理后，重新运行配置包。'
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
        $controls.Details.Text = if ($Restore) { "已恢复：$Modules`n所选模块已还原到首次安装前的设置。" } else { "已配置：$Modules`n首次备份已保留，双击 恢复原界面.vbs 即可恢复。" }
        $controls.Footer.Text = '已完成 · 可以关闭此窗口'
    }
})
$controls.CloseButton.Add_Click({ $window.Close() })
$window.Add_Closing({ param($sender,$event) if ($ui.Running) { $event.Cancel=$true } })
$window.Add_ContentRendered({
    if ($ui.Handle) { return }
    $ui.Handle = $job.BeginInvoke()
    $timer.Start()
})
try { $null = $window.ShowDialog() }
finally { $timer.Stop(); if ($ui.Running) { $job.Dispose() } }
exit $ui.ExitCode
