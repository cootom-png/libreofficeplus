$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$fixture = Join-Path $repo ('.test-work\' + [guid]::NewGuid().ToString('N'))
$profile = Join-Path $fixture 'LibreOffice\4\user'
$config = Join-Path $profile 'registrymodifications.xcu'
$backup = Join-Path $fixture 'LibreOffice\wps-ui-backup.xml'
$fakeInstall = Join-Path $fixture 'app'
$installer = Join-Path $repo 'package\configure.ps1'
$ns = 'http://openoffice.org/2001/registry'
New-Item -ItemType Directory -Path $profile,"$fakeInstall\program" -Force | Out-Null
[IO.File]::WriteAllText("$fakeInstall\program\version.ini", 'buildid=cd7284b4cbbfeb507e630c1aac019f4157393acb')
$initial = @'
<oor:items xmlns:oor="http://openoffice.org/2001/registry">
<item oor:path="/org.openoffice.Office.UI.ToolbarMode"><prop oor:name="ActiveWriter" oor:op="fuse"><value>original.ui</value></prop><prop oor:name="Unrelated" oor:op="fuse"><value>keep</value></prop></item>
<item oor:path="/org.openoffice.Office.UI.WriterCommands/UserInterface/Commands/.uno:FormatPaintbrush"><prop oor:name="Label" oor:op="fuse"><value xml:lang="zh-CN">原始名称</value><value xml:lang="en-US">Custom name</value></prop></item>
<item oor:path="/org.openoffice.Office.Accelerators/PrimaryKeys/Modules/org.openoffice.Office.Accelerators:Module['com.sun.star.text.TextDocument']/org.openoffice.Office.Accelerators:Key['D_MOD1']/Command"><value xml:lang="en-US">.uno:UnderlineDouble</value><value xml:lang="zh-CN">.uno:CustomFont</value></item>
</oor:items>
'@
[IO.File]::WriteAllText($config,$initial,[Text.UTF8Encoding]::new($false))
$oldUi = '<interface><object class="GtkBox" id="original"/></interface>'
$writerUi = Join-Path $profile 'config\soffice.cfg\modules\swriter\ui\notebookbar.ui'
$calcUi = Join-Path $profile 'config\soffice.cfg\modules\scalc\ui\notebookbar.ui'
$drawUi = Join-Path $profile 'config\soffice.cfg\modules\sdraw\ui\notebookbar.ui'
New-Item -ItemType Directory -Path (Split-Path $writerUi) -Force | Out-Null
[IO.File]::WriteAllText($writerUi,$oldUi)
function Semantic($text) {
    [xml]$xml = $text
    @($xml.DocumentElement.SelectNodes('item') | ForEach-Object {
        $path = [regex]::Replace($_.GetAttribute('path',$ns), "[^/:\[\]]+:[^/:\[\]]+\['([^']*)'\]", '$1')
        $props=@($_.SelectNodes('prop'))
        if (!$props.Count) {
            $name=$path.Substring($path.LastIndexOf('/')+1); $path=$path.Substring(0,$path.LastIndexOf('/'))
            $props=@($_)
        }
        foreach ($prop in $props) {
            if ($prop.LocalName -eq 'prop') { $name=$prop.GetAttribute('name',$ns) }
            $values=@($prop.SelectNodes('value') | ForEach-Object { "$($_.GetAttribute('lang','http://www.w3.org/XML/1998/namespace'))=$($_.InnerText)" }) -join ';'
            "$path|$name|$values"
        }
    } | Sort-Object)
}
function Simulate-NativeSave {
    [xml]$xml=Get-Content -LiteralPath $config -Raw -Encoding UTF8
    foreach ($item in @($xml.DocumentElement.SelectNodes('item'))) {
        foreach ($prop in @($item.SelectNodes('prop'))) {
            if (!@($prop.SelectNodes('value') | Where-Object { $_.HasAttribute('lang','http://www.w3.org/XML/1998/namespace') }).Count) { continue }
            $path=$item.GetAttribute('path',$ns)
            if ($path -match '/Modules/com.sun.star.text.TextDocument/([^/]+)$') {
                $path="/org.openoffice.Office.Accelerators/PrimaryKeys/Modules/org.openoffice.Office.Accelerators:Module['com.sun.star.text.TextDocument']/org.openoffice.Office.Accelerators:Key['$($Matches[1])']"
            }
            $direct=$xml.CreateElement('item'); $direct.SetAttribute('path',$ns,"$path/$($prop.GetAttribute('name',$ns))") | Out-Null
            foreach ($value in $prop.SelectNodes('value')) { $direct.AppendChild($value.CloneNode($true)) | Out-Null }
            $xml.DocumentElement.AppendChild($direct) | Out-Null; $item.RemoveChild($prop) | Out-Null
        }
        if (!$item.HasChildNodes) { $xml.DocumentElement.RemoveChild($item) | Out-Null }
    }
    $xml.Save($config)
}
function Check-Restore {
    if ((Get-Content -LiteralPath $writerUi -Raw) -ne $oldUi) { throw '原界面未恢复' }
    if (Test-Path -LiteralPath $calcUi) { throw '新增界面未删除' }
    if (Test-Path -LiteralPath $drawUi) { throw '新增 Draw 界面未删除' }
    if (Compare-Object (Semantic $initial) (Semantic (Get-Content -LiteralPath $config -Raw -Encoding UTF8))) { throw '恢复结果与原设置不同' }
}
$originalAppData = $env:APPDATA
try {
    $env:APPDATA = $fixture
    # 仅对隔离配置目录进行文件测试，不访问真实用户配置或结束任何进程。
    function Get-Process { param($Name,$ErrorAction) }
    $progress = [Collections.Generic.List[int]]::new()
    & $installer -LibreOfficePath $fakeInstall -OnProgress { param($Percent,$Message) $progress.Add($Percent) }
    if ($progress[0] -ne 5 -or $progress[$progress.Count-1] -ne 100) { throw '安装进度缺少起点或完成状态' }
    for ($index=1; $index -lt $progress.Count; $index++) {
        if ($progress[$index] -lt $progress[$index-1] -or $progress[$index] -gt 100) { throw '安装进度倒退或越界' }
    }
    [xml]$installed = Get-Content -LiteralPath $config -Raw -Encoding UTF8
    if (!@($installed.SelectNodes('//value') | Where-Object { $_.GetAttribute('lang','http://www.w3.org/XML/1998/namespace') -eq 'zh-CN' -and $_.InnerText -eq '格式刷' }).Count) { throw '中文名称未写入' }
    if (!@($installed.SelectNodes('//value') | Where-Object { $_.GetAttribute('lang','http://www.w3.org/XML/1998/namespace') -eq 'en-US' -and $_.InnerText -eq '.uno:FontDialog' }).Count) { throw 'WPS 快捷键未写入' }
    $hash = (Get-FileHash -LiteralPath $backup).Hash
    & $installer -LibreOfficePath $fakeInstall
    if ((Get-FileHash -LiteralPath $backup).Hash -ne $hash) { throw '重复安装覆盖了首次备份' }
    Simulate-NativeSave
    & $installer -Restore
    Check-Restore
    Write-Host '通过：安装、重复安装、首次备份、中文名称、多语言恢复、UI 文件还原。'

    # 模拟 v3 已安装的配置及首次备份，验证升级后仍回到 v3 安装前。
    [xml]$legacy = $initial
    $legacy.DocumentElement.SelectSingleNode('item/prop/value').InnerText = 'notebookbar.ui'
    $legacy.Save($config)
    [xml]$oldBackup = '<backup version="3"/>'
    [xml]$original = $initial
    $oldBackup.DocumentElement.AppendChild($oldBackup.ImportNode($original.DocumentElement.FirstChild,$true)) | Out-Null
    $oldBackup.Save($backup)
    & $installer -LibreOfficePath $fakeInstall
    & $installer -Restore
    Check-Restore
    Write-Host '通过：v3 升级到 v5 后恢复首次配置。'

    # 先单独安装 Draw，再追加两个模块；部分恢复不得覆盖其他模块。
    & $installer -Modules Draw -LibreOfficePath $fakeInstall
    if (!(Test-Path -LiteralPath $drawUi) -or (Test-Path -LiteralPath $calcUi) -or (Get-Content -LiteralPath $writerUi -Raw) -ne $oldUi) { throw '按模块安装修改了其他界面' }
    [xml]$drawOnly=Get-Content -LiteralPath $config -Raw -Encoding UTF8
    if (@($drawOnly.SelectNodes('/*/item/prop') | Where-Object { $_.GetAttribute('name',$ns) -eq 'ActiveCalc' }).Count) { throw 'Draw 安装写入 Calc 设置' }
    if (@($drawOnly.SelectNodes('//value') | Where-Object { $_.InnerText -eq '.uno:FontDialog' }).Count) { throw 'Draw 安装修改 Writer 快捷键' }
    & $installer -Modules 'Writer,Calc' -LibreOfficePath $fakeInstall
    Simulate-NativeSave
    $writerHash=(Get-FileHash -LiteralPath $writerUi).Hash
    $calcHash=(Get-FileHash -LiteralPath $calcUi).Hash
    & $installer -Modules Draw -Restore
    if ((Test-Path -LiteralPath $drawUi) -or (Get-FileHash -LiteralPath $writerUi).Hash -ne $writerHash -or (Get-FileHash -LiteralPath $calcUi).Hash -ne $calcHash) { throw '部分恢复修改了其他模块' }
    & $installer -Modules Writer -Restore
    if ((Get-FileHash -LiteralPath $calcUi).Hash -ne $calcHash) { throw '恢复 Writer 修改了 Calc' }
    & $installer -Modules Calc -Restore
    Check-Restore
    Write-Host '通过：独立安装、追加安装、逐模块恢复与共享设置最后恢复。'

    # 使用仓库 main 的真实 v4 安装程序创建旧备份，验证升级和部分恢复。
    $v4dir=Join-Path $fixture 'v4'; New-Item -ItemType Directory -Path $v4dir | Out-Null
    foreach ($file in @('设置界面.ps1','设置清单.json')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "fixtures\v4\$file") -Destination (Join-Path $v4dir $file)
    }
    New-Item -ItemType Directory -Path (Join-Path $v4dir 'ui') | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'package\ui\swriter'),(Join-Path $repo 'package\ui\scalc') -Destination (Join-Path $v4dir 'ui') -Recurse
    & (Join-Path $v4dir '设置界面.ps1') -LibreOfficePath $fakeInstall
    & $installer -LibreOfficePath $fakeInstall
    & $installer -Modules Draw -Restore
    & $installer -Modules 'Writer,Calc' -Restore
    Check-Restore
    Write-Host '通过：真实 v4 备份升级到 v5 并分模块恢复。'

    $before = (Get-FileHash -LiteralPath $config).Hash
    function Copy-Item {
        param([string]$LiteralPath,[string]$Destination,[switch]$Force)
        if ($Destination -eq $calcUi) { throw '模拟第二个 UI 文件写入失败' }
        Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
    }
    $failed = $false
    $progress.Clear()
    try { & $installer -LibreOfficePath $fakeInstall -OnProgress { param($Percent,$Message) $progress.Add($Percent) } } catch { $failed = $true }
    finally { Remove-Item Function:\Copy-Item }
    if (!$failed -or (Get-FileHash -LiteralPath $config).Hash -ne $before) { throw '失败后配置未保持原值' }
    if ($progress.Contains(100)) { throw '写入失败不应报告完成' }
    Check-Restore
    & $installer -Restore
    Check-Restore
    Write-Host '通过：第二个 UI 写入失败时撤回第一个 UI，保留配置和恢复能力。'

    [IO.File]::WriteAllText("$fakeInstall\program\version.ini",'buildid=unsupported')
    $before = (Get-FileHash -LiteralPath $config).Hash
    $refused = $false
    try { & $installer -LibreOfficePath $fakeInstall } catch { $refused = $true }
    if (!$refused -or (Get-FileHash -LiteralPath $config).Hash -ne $before) { throw '未阻止不匹配版本' }
    function Get-Process { param($Name,$ErrorAction) [pscustomobject]@{ ProcessName='soffice' } }
    $refused = $false
    try { & $installer -Restore } catch { $refused = $true }
    if (!$refused -or (Get-FileHash -LiteralPath $config).Hash -ne $before) { throw '运行中防护未生效' }
    Write-Host '通过：不兼容版本和运行中进程防护。'
} finally {
    $env:APPDATA = $originalAppData
    Remove-Item Function:\Get-Process -ErrorAction SilentlyContinue
    # 测试目录保留用于故障诊断，.gitignore 排除；不递归删除任何用户目录。
}
