$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$package = Join-Path $repo 'package'
foreach ($name in 'configure.ps1','installer-ui.ps1') {
    $tokens=$null; $parseErrors=$null
    [Management.Automation.Language.Parser]::ParseFile((Join-Path $package $name),[ref]$tokens,[ref]$parseErrors) | Out-Null
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
    $bytes=[IO.File]::ReadAllBytes((Join-Path $package $name))
    if ($bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191) { throw "$name 缺少 UTF-8 BOM" }
}
Add-Type -AssemblyName PresentationFramework
[xml]$layout=Get-Content -LiteralPath (Join-Path $package 'installer.xaml') -Raw -Encoding UTF8
$window=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($layout))
foreach ($name in 'Heading','Subtitle','StatusTitle','Percent','Progress','StatusMessage','Step1','Step2','Step3','Checks','Details','Footer','CloseButton') {
    if (!$window.FindName($name)) { throw "界面控件缺失：$name" }
}
if ($window.FindName('CloseButton').IsEnabled) { throw '运行期间不应允许关闭' }
$window.Close()
Write-Host '通过：Windows PowerShell 5.1 语法、中文编码、WPF 界面加载和必要控件。'

# 在独立配置与受控副本中验证后台检查、界面绑定和最终结果，不接触个人文档。
$fixture=Join-Path $repo ('.test-work\gui-checks-' + [guid]::NewGuid().ToString('N'))
$bundle=Join-Path $fixture 'bundle'
New-Item -ItemType Directory -Path $bundle -Force | Out-Null
Get-ChildItem -LiteralPath $package | Copy-Item -Destination $bundle -Recurse -Force
$core=Join-Path $bundle 'configure.ps1'
$source=[IO.File]::ReadAllText($core).Replace("(Get-Process -Name 'soffice','soffice.bin' -ErrorAction SilentlyContinue)","(Test-Path -LiteralPath (Join-Path `$PSScriptRoot 'simulate-running'))")
[IO.File]::WriteAllText($core,$source,[Text.UTF8Encoding]::new($true))
$controller=Join-Path $bundle 'installer-ui.ps1'
$source=[IO.File]::ReadAllText($controller)
$needle='})' + "`n" + '$controls.CloseButton.Add_Click'
if (!$source.Contains($needle)) { throw '图形验收插入点不存在' }
$capture=@'
    $controls.Checks.UpdateLayout()
    $window.UpdateLayout()
    $record=@{Title=$controls.StatusTitle.Text;Percent=$controls.Percent.Text;Progress=$controls.Progress.Value;Failure=$state.Failure;Checks=@($controls.Checks.ItemsSource)}
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'ui-result.json'),($record | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($true))
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
    if ($badTitle) {
        if ($process.ExitCode -ne 1 -or !$result.Failure -or $result.Progress -eq 100 -or $result.Percent -ne '需要处理') { throw "图形失败状态不正确：$name" }
        $row=$result.Checks | Where-Object { $_.Title -eq $badTitle }
        if ($row.State -ne '需处理' -or $row.Color -ne '#C83939') { throw "图形检查项未标红：$name" }
    } elseif ($process.ExitCode -ne 0 -or $result.Failure -or $result.Progress -ne 100 -or $result.Checks.Count -ne 8 -or @($result.Checks | Where-Object { $_.State -notin @('通过','不适用') }).Count) { throw "图形成功状态不正确：$name" }
    Copy-Item -LiteralPath (Join-Path $bundle 'ui-result.json') -Destination (Join-Path $fixture "$name.json")
    Copy-Item -LiteralPath (Join-Path $bundle 'ui-preview.png') -Destination (Join-Path $fixture "$name.png")
    Write-Host "通过：图形窗口$name。"
}
try {
    $env:APPDATA=Join-Path $fixture 'appdata'
    Run-UI '安装检查' '' ''
    Run-UI '恢复检查' '-Restore' ''
    $before=(Get-FileHash -LiteralPath $config).Hash
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
