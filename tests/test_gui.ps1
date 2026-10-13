$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$package = Join-Path $repo 'package'
foreach ($name in 'configure.ps1','installer-ui.ps1','upgrade.ps1') {
    $tokens=$null; $parseErrors=$null
    [Management.Automation.Language.Parser]::ParseFile((Join-Path $package $name),[ref]$tokens,[ref]$parseErrors) | Out-Null
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
    $bytes=[IO.File]::ReadAllBytes((Join-Path $package $name))
    if ($bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191) { throw "$name 缺少 UTF-8 BOM" }
}
Add-Type -AssemblyName PresentationFramework
[xml]$layout=Get-Content -LiteralPath (Join-Path $package 'installer.xaml') -Raw -Encoding UTF8
$window=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($layout))
foreach ($name in 'Heading','Subtitle','StatusTitle','Percent','Progress','ProgressPanel','StatusMessage','Step1','Step2','Step3','Checks','Details','Footer','CloseButton','VersionLabel','SelectionPanel','ModuleWriter','ModuleCalc','ModuleDraw','ModuleImpress','ApplicationPath','FontNotice','TemplatesButton','StartButton','ModuleHeading','UpgradeButton','PackageButton') {
    if (!$window.FindName($name)) { throw "界面控件缺失：$name" }
}
if ($window.FindName('Checks').Visibility -ne 'Collapsed' -or $window.FindName('ProgressPanel').Visibility -ne 'Collapsed') { throw '开始前不应显示等待中的检查与进度' }
if (!$window.FindName('CloseButton').IsEnabled) { throw '开始前应允许取消' }
$window.Close()
Write-Host '通过：Windows PowerShell 5.1 语法、中文编码、WPF 界面加载和必要控件。'

# 在独立配置与受控副本中验证后台检查、界面绑定和最终结果，不接触个人文档。
$fixture=Join-Path $repo ('.test-work\gui-checks-' + [guid]::NewGuid().ToString('N'))
$bundle=Join-Path $fixture 'bundle'
New-Item -ItemType Directory -Path $bundle -Force | Out-Null
Get-ChildItem -LiteralPath $package | Copy-Item -Destination $bundle -Recurse -Force
$core=Join-Path $bundle 'configure.ps1'
$source=[IO.File]::ReadAllText($core).Replace("(Get-Process -Name 'soffice','soffice.bin','updater' -ErrorAction SilentlyContinue)","(Test-Path -LiteralPath (Join-Path `$PSScriptRoot 'simulate-running'))")
[IO.File]::WriteAllText($core,$source,[Text.UTF8Encoding]::new($true))
$controller=Join-Path $bundle 'installer-ui.ps1'
$source=[IO.File]::ReadAllText($controller)
$needle='})' + "`n" + '$controls.CloseButton.Add_Click'
if (!$source.Contains($needle)) { throw '图形验收插入点不存在' }
$capture=@'
    $controls.Checks.UpdateLayout()
    $window.UpdateLayout()
    $record=@{Title=$controls.StatusTitle.Text;Percent=$controls.Percent.Text;Progress=$controls.Progress.Value;Failure=$state.Failure;ProgressVisible=($controls.ProgressPanel.Visibility -eq 'Visible');ChecksVisible=($controls.Checks.Visibility -eq 'Visible');Checks=@($controls.Checks.ItemsSource);Modules=$ui.Modules;Version=$controls.VersionLabel.Text}
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'ui-result.json'),($record | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($true))
    # 公开预览仅替换合成安装目录的显示文字；实际检查记录保留原值。
    $controls.Checks.ItemsSource=@($controls.Checks.ItemsSource | ForEach-Object {
        [pscustomobject]@{Title=$_.Title;State=$_.State;Color=$_.Color;Message=$(if ($_.Title -eq '安装目录' -and $_.State -eq '通过') { 'C:\Program Files\LibreOffice' } else { $_.Message })}
    })
    $window.UpdateLayout()
    $content=$window.Content
    $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$content.ActualWidth,[int]$content.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($content)
    $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream=[IO.File]::Create((Join-Path $PSScriptRoot 'ui-preview.png'))
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
    $window.Close()
'@
[IO.File]::WriteAllText($controller,$source.Replace($needle,($capture + "`n" + $needle)),[Text.UTF8Encoding]::new($true))
# 仅在受控副本中模拟用户点开始；生产窗口保持等待选择。
$source=[IO.File]::ReadAllText($controller)
$start=@'
$window.Add_ContentRendered({
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'empty-selection')) {
        foreach ($module in 'Writer','Calc','Draw','Impress') { $controls["Module$module"].IsChecked=$false }
        $controls.StartButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        if ($ui.Handle -or $ui.Running -or $controls.StatusMessage.Text -ne '请至少选择一个模块。') { throw '空模块选择没有阻止操作' }
        [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'empty-result'),'blocked')
        $ui.ExitCode=0; $window.Close(); return
    }
    $window.Width=680; $window.Height=600; $window.UpdateLayout()
    $actualPath=$controls.ApplicationPath.Text
    $controls.ApplicationPath.Text='C:\Program Files\LibreOffice'
    $window.UpdateLayout()
    $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$window.Content.ActualWidth,[int]$window.Content.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($window.Content)
    $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream=[IO.File]::Create((Join-Path $PSScriptRoot 'setup-preview.png'))
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
    $controls.ApplicationPath.Text=$actualPath
    $controls.StartButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
})
'@
$source=$source.Replace('try { $null = $window.ShowDialog() }',($start + "`n" + 'try { $null = $window.ShowDialog() }'))
[IO.File]::WriteAllText($controller,$source,[Text.UTF8Encoding]::new($true))
$previousAppData=$env:APPDATA
$fakeApp=Join-Path $fixture 'app'
$profile=Join-Path $fixture 'appdata\LibreOffice\4\user'
$config=Join-Path $profile 'registrymodifications.xcu'
New-Item -ItemType Directory -Path "$fakeApp\program",$profile -Force | Out-Null
[IO.File]::WriteAllText("$fakeApp\program\soffice.exe",'')
[IO.File]::WriteAllText("$fakeApp\program\version.ini",'buildid=cd7284b4cbbfeb507e630c1aac019f4157393acb')
[IO.File]::WriteAllText($config,'<oor:items xmlns:oor="http://openoffice.org/2001/registry"/>')
function Run-UI($name,$arguments,$badTitle) {
    $command='-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $controller + '" -LibreOfficePath "' + $fakeApp + '" ' + $arguments
    $process=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $command -WindowStyle Hidden -PassThru
    if (!$process.WaitForExit(30000)) { throw "图形检查超时：$name" }
    $result=Get-Content -LiteralPath (Join-Path $bundle 'ui-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $expectedVersion='v' + (Get-Content -LiteralPath (Join-Path $bundle 'version.json') -Raw -Encoding UTF8 | ConvertFrom-Json).Version
    if (!$result.ProgressVisible -or !$result.ChecksVisible) { throw '开始后未显示进度和检查列表' }
    if ($result.Version -ne $expectedVersion) { throw '安装窗口版本号不正确' }
    if ($badTitle) {
        if ($process.ExitCode -ne 1 -or !$result.Failure -or $result.Progress -eq 100 -or $result.Percent -ne '需要处理') { throw "图形失败状态不正确：$name" }
        $row=$result.Checks | Where-Object { $_.Title -eq $badTitle }
        if ($row.State -ne '需处理' -or $row.Color -ne '#B3261E') { throw "图形检查项未标红：$name" }
    } elseif ($process.ExitCode -ne 0 -or $result.Failure -or $result.Progress -ne 100 -or $result.Checks.Count -ne 8 -or @($result.Checks | Where-Object { $_.State -notin @('通过','不适用') }).Count) { throw "图形成功状态不正确：$name" }
    Copy-Item -LiteralPath (Join-Path $bundle 'ui-result.json') -Destination (Join-Path $fixture "$name.json")
    Copy-Item -LiteralPath (Join-Path $bundle 'ui-preview.png') -Destination (Join-Path $fixture "$name.png")
    Copy-Item -LiteralPath (Join-Path $bundle 'setup-preview.png') -Destination (Join-Path $fixture "$name-选择.png")
    Write-Host "通过：图形窗口$name。"
}
try {
    $env:APPDATA=Join-Path $fixture 'appdata'
    Run-UI '安装检查' '' ''
    Run-UI '恢复检查' '-Restore' ''
    Run-UI '仅文字模块' '-Modules Writer' ''
    $result=Get-Content -LiteralPath (Join-Path $bundle 'ui-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($result.Modules -ne 'Writer' -or (Test-Path -LiteralPath (Join-Path $profile 'config\soffice.cfg\modules\scalc\ui\notebookbar.ui'))) { throw '模块选择未隔离' }
    Run-UI '仅文字恢复' '-Restore -Modules Writer' ''
    Run-UI '仅演示模块' '-Modules Impress' ''
    $result=Get-Content -LiteralPath (Join-Path $bundle 'ui-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($result.Modules -ne 'Impress' -or !(Test-Path -LiteralPath (Join-Path $profile 'config\soffice.cfg\modules\simpress\ui\notebookbar.ui')) -or (Test-Path -LiteralPath (Join-Path $profile 'config\soffice.cfg\modules\swriter\ui\notebookbar.ui'))) { throw '演示图形模块选择未隔离' }
    Run-UI '仅演示恢复' '-Restore -Modules Impress' ''
    [IO.File]::WriteAllText("$fakeApp\program\version.ini",'buildid=bf6ef2662401c7d6dce671ab4deb26ee0af3a7c1')
    Run-UI '新版安装检查' '' ''
    $result=Get-Content -LiteralPath (Join-Path $bundle 'ui-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if (($result.Checks | Where-Object { $_.Title -eq '版本兼容' }).Message -notmatch '26.8.1.1') { throw '图形窗口未显示新版兼容结果' }
    $source=Join-Path $bundle 'variants\26.8.1\ui\swriter\notebookbar.ui'
    $target=Join-Path $profile 'config\soffice.cfg\modules\swriter\ui\notebookbar.ui'
    if ((Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $target).Hash) { throw '图形安装未选择新版文件' }
    Run-UI '新版恢复检查' '-Restore' ''
    [IO.File]::WriteAllText("$fakeApp\program\version.ini",'buildid=cd7284b4cbbfeb507e630c1aac019f4157393acb')
    $before=(Get-FileHash -LiteralPath $config).Hash
    [IO.File]::WriteAllText((Join-Path $bundle 'empty-selection'),'')
    $process=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList ('-NoProfile -STA -ExecutionPolicy Bypass -File "' + $controller + '"') -WindowStyle Hidden -PassThru
    if (!$process.WaitForExit(30000) -or $process.ExitCode -ne 0 -or !(Test-Path -LiteralPath (Join-Path $bundle 'empty-result'))) { throw '空模块选择检查失败' }
    [IO.File]::Delete((Join-Path $bundle 'empty-selection'))
    if ((Get-FileHash -LiteralPath $config).Hash -ne $before) { throw '空选择修改了设置' }
    Write-Host '通过：空模块选择阻止配置。'
    Run-UI '升级版本识别失败' '-Upgrade' '升级结果'
    [IO.File]::WriteAllText("$fakeApp\program\version.ini",'buildid=unsupported')
    Run-UI '不兼容版本' '' '版本兼容'
    [IO.File]::WriteAllText("$fakeApp\program\version.ini",'buildid=cd7284b4cbbfeb507e630c1aac019f4157393acb')
    [IO.File]::Move("$fakeApp\program\soffice.exe","$fakeApp\program\soffice.saved")
    Run-UI '程序缺失' '' '安装目录'
    [IO.File]::Move("$fakeApp\program\soffice.saved","$fakeApp\program\soffice.exe")
    [IO.File]::WriteAllText((Join-Path $bundle 'simulate-running'),'')
    Run-UI '软件运行中' '' '运行状态'
    [IO.File]::Delete((Join-Path $bundle 'simulate-running'))
    [IO.File]::Move($config,"$config.saved")
    Run-UI '用户配置缺失' '' '用户配置'
    [IO.File]::Move("$config.saved",$config)
    [IO.File]::WriteAllText((Join-Path $bundle 'profile-files.json'),'invalid json')
    Run-UI '配置包损坏' '' '配置包文件'
    if ((Get-FileHash -LiteralPath $config).Hash -ne $before -or (Test-Path -LiteralPath (Join-Path $fixture 'appdata\LibreOffice\wps-ui-backup.xml'))) { throw '检查失败后修改了用户设置或创建了备份' }
} finally { $env:APPDATA=$previousAppData }
Write-Host "图形验收结果与渲染预览：$fixture"
