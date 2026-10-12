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
foreach ($name in 'Heading','Subtitle','StatusTitle','Percent','Progress','StatusMessage','Step1','Step2','Step3','Details','Footer','CloseButton') {
    if (!$window.FindName($name)) { throw "界面控件缺失：$name" }
}
if ($window.FindName('CloseButton').IsEnabled) { throw '运行期间不应允许关闭' }
$window.Close()
Write-Host '通过：Windows PowerShell 5.1 语法、中文编码、WPF 界面加载和必要控件。'
