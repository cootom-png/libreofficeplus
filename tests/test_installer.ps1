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
[IO.File]::WriteAllText("$fakeInstall\program\soffice.exe", '')
$initial = @'
<oor:items xmlns:oor="http://openoffice.org/2001/registry">
<item oor:path="/org.openoffice.Office.UI.ToolbarMode"><prop oor:name="ActiveWriter" oor:op="fuse"><value>original.ui</value></prop><prop oor:name="Unrelated" oor:op="fuse"><value>keep</value></prop></item>
<item oor:path="/org.openoffice.Office.UI.WriterCommands/UserInterface/Commands/.uno:FormatPaintbrush"><prop oor:name="Label" oor:op="fuse"><value xml:lang="zh-CN">原始名称</value><value xml:lang="en-US">Custom name</value></prop></item>
<item oor:path="/org.openoffice.Office.Accelerators/PrimaryKeys/Modules/org.openoffice.Office.Accelerators:Module['com.sun.star.text.TextDocument']/org.openoffice.Office.Accelerators:Key['D_MOD1']/Command"><value xml:lang="en-US">.uno:UnderlineDouble</value><value xml:lang="zh-CN">.uno:CustomFont</value></item>
<item oor:path="/org.openoffice.Office.Accelerators/PrimaryKeys/Modules/com.sun.star.sheet.SpreadsheetDocument/R_MOD1"><prop oor:name="Command" oor:op="fuse"><value xml:lang="en-US">.uno:CustomCalcRight</value></prop></item>
<item oor:path="/org.openoffice.Office.Accelerators/PrimaryKeys/Modules/com.sun.star.drawing.DrawingDocument/G_SHIFT_MOD1"><prop oor:name="Command" oor:op="fuse"><value xml:lang="en-US">.uno:CustomDrawGroup</value></prop></item>
<item oor:path="/org.openoffice.Office.Accelerators/PrimaryKeys/Modules/com.sun.star.drawing.DrawingDocument"><node oor:name="G_MOD1" oor:op="replace"><prop oor:name="Command" oor:op="fuse"><value xml:lang="en-US">.uno:CustomGroup</value></prop></node><node oor:name="H_MOD1" oor:op="replace"><prop oor:name="Command" oor:op="fuse"><value xml:lang="en-US">.uno:CustomSibling</value></prop></node></item>
<item oor:path="/org.openoffice.Office.Accelerators/PrimaryKeys/Modules/com.sun.star.text.TextDocument/K_MOD1"><prop oor:name="Command" oor:op="fuse"><value xml:lang="en-US">.uno:CustomPersonalKey</value></prop></item>
<item oor:path="/org.openoffice.Office.Accelerators/PrimaryKeys/Modules/com.sun.star.presentation.PresentationDocument/M_MOD1"><prop oor:name="Command" oor:op="fuse"><value xml:lang="en-US">.uno:CustomImpressKey</value></prop></item>
</oor:items>
'@
[IO.File]::WriteAllText($config,$initial,[Text.UTF8Encoding]::new($false))
$oldUi = '<interface><object class="GtkBox" id="original"/></interface>'
$writerUi = Join-Path $profile 'config\soffice.cfg\modules\swriter\ui\notebookbar.ui'
$calcUi = Join-Path $profile 'config\soffice.cfg\modules\scalc\ui\notebookbar.ui'
$impressUi = Join-Path $profile 'config\soffice.cfg\modules\simpress\ui\notebookbar.ui'
$drawUi = Join-Path $profile 'config\soffice.cfg\modules\sdraw\ui\notebookbar.ui'
New-Item -ItemType Directory -Path (Split-Path $writerUi) -Force | Out-Null
[IO.File]::WriteAllText($writerUi,$oldUi)
$writerMenu = Join-Path $profile 'config\soffice.cfg\modules\swriter\popupmenu\text.xml'
$calcMenu = Join-Path $profile 'config\soffice.cfg\modules\scalc\popupmenu\cell.xml'
$impressMenu = Join-Path $profile 'config\soffice.cfg\modules\simpress\popupmenu\pagepane.xml'
$drawMenu = Join-Path $profile 'config\soffice.cfg\modules\sdraw\popupmenu\draw.xml'
$oldMenu = '<menu:menupopup xmlns:menu="http://openoffice.org/2001/menu"><menu:menuitem menu:id=".uno:Copy"/></menu:menupopup>'
New-Item -ItemType Directory -Path (Split-Path $writerMenu) -Force | Out-Null
[IO.File]::WriteAllText($writerMenu,$oldMenu)
function Semantic($text) {
    [xml]$xml = $text
    function Values($node,$path) {
        $path=[regex]::Replace($path, "[^/:\[\]]+:[^/:\[\]]+\['([^']*)'\]", '$1')
        foreach ($prop in $node.SelectNodes('prop')) {
            $values=@($prop.SelectNodes('value') | ForEach-Object { "$($_.GetAttribute('lang','http://www.w3.org/XML/1998/namespace'))=$($_.InnerText)" }) -join ';'
            "$path|$($prop.GetAttribute('name',$ns))|$values"
        }
        if (@($node.SelectNodes('value')).Count) {
            $name=$path.Substring($path.LastIndexOf('/')+1); $parent=$path.Substring(0,$path.LastIndexOf('/'))
            $values=@($node.SelectNodes('value') | ForEach-Object { "$($_.GetAttribute('lang','http://www.w3.org/XML/1998/namespace'))=$($_.InnerText)" }) -join ';'
            "$parent|$name|$values"
        }
        foreach ($child in $node.SelectNodes('node')) { Values $child "$path/$($child.GetAttribute('name',$ns))" }
    }
    @($xml.DocumentElement.SelectNodes('item') | ForEach-Object { Values $_ ($_.GetAttribute('path',$ns)) } | Sort-Object)
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
    if ((Test-Path -LiteralPath $impressUi) -or (Test-Path -LiteralPath $impressMenu)) { throw '演示模块未恢复' }
    if (Test-Path -LiteralPath $drawUi) { throw '新增 Draw 界面未删除' }
    if ((Get-Content -LiteralPath $writerMenu -Raw) -ne $oldMenu) { throw '首次自定义菜单未恢复' }
    if ((Test-Path -LiteralPath $calcMenu) -or (Test-Path -LiteralPath $drawMenu)) { throw '新增菜单未删除' }
    if (Compare-Object (Semantic $initial) (Semantic (Get-Content -LiteralPath $config -Raw -Encoding UTF8))) { throw '恢复结果与原设置不同' }
}
$originalAppData = $env:APPDATA
try {
    $env:APPDATA = $fixture
    # 仅对隔离配置目录进行文件测试，不访问真实用户配置或结束任何进程。
    function Get-Process { param($Name,$ErrorAction) }
    $progress = [Collections.Generic.List[int]]::new()
    $checks = [Collections.Generic.List[object]]::new()
    & $installer -LibreOfficePath $fakeInstall -OnProgress { param($Percent,$Message) $progress.Add($Percent) } -OnCheck { param($Result) $checks.Add($Result) }
    if ($checks.Count -ne 8 -or @($checks | Where-Object { $_.State -ne '通过' }).Count) { throw '安装前检查未全部通过' }
    if (($checks | Where-Object { $_.Title -eq '版本兼容' }).Message -notmatch '26.2.5.2') { throw '未显示适配版本' }
    if (Get-ChildItem -LiteralPath $profile -Filter '.wps-check-*.tmp') { throw '权限检查文件未清理' }
    if ($progress[0] -ne 5 -or $progress[$progress.Count-1] -ne 100) { throw '安装进度缺少起点或完成状态' }
    for ($index=1; $index -lt $progress.Count; $index++) {
        if ($progress[$index] -lt $progress[$index-1] -or $progress[$index] -gt 100) { throw '安装进度倒退或越界' }
    }
    [xml]$installed = Get-Content -LiteralPath $config -Raw -Encoding UTF8
    foreach ($name in 'AutoCheckEnabled','AutoDownloadEnabled','Enabled') {
        $props=@($installed.SelectNodes('//prop') | Where-Object { $_.GetAttribute('name',$ns) -eq $name })
        if ($props.Count -ne 1 -or $props[0].value -ne 'false' -or $props[0].GetAttribute('type',$ns) -ne 'xs:boolean') { throw "未按布尔类型关闭官方更新设置：$name" }
    }
    if (!@($installed.SelectNodes('//value') | Where-Object { $_.GetAttribute('lang','http://www.w3.org/XML/1998/namespace') -eq 'zh-CN' -and $_.InnerText -eq '格式刷' }).Count) { throw '中文名称未写入' }
    if (!@($installed.SelectNodes('//value') | Where-Object { $_.GetAttribute('lang','http://www.w3.org/XML/1998/namespace') -eq 'en-US' -and $_.InnerText -eq '.uno:FontDialog' }).Count) { throw 'WPS 快捷键未写入' }
    foreach ($entry in (Get-Content (Join-Path $repo 'config/shortcuts.json') -Raw -Encoding UTF8 | ConvertFrom-Json)) {
        $expected="$($entry.Path)|Command|en-US=$($entry.Value)"
        if ($expected -notin (Semantic $installed.OuterXml)) { throw "快捷键配置未写入：$($entry.Path)" }
    }
    $hash = (Get-FileHash -LiteralPath $backup).Hash
    $menuHash = (Get-FileHash -LiteralPath (Join-Path $fixture 'LibreOffice\wps-ui-files-backup\swriter-text.xml')).Hash
    if (!(Test-Path -LiteralPath $calcMenu) -or !(Test-Path -LiteralPath $drawMenu)) { throw '所选模块的菜单未安装' }
    & $installer -LibreOfficePath $fakeInstall
    if ((Get-FileHash -LiteralPath $backup).Hash -ne $hash) { throw '重复安装覆盖了首次备份' }
    if ((Get-FileHash -LiteralPath (Join-Path $fixture 'LibreOffice\wps-ui-files-backup\swriter-text.xml')).Hash -ne $menuHash) { throw '重复安装覆盖了首次菜单备份' }
    Simulate-NativeSave
    & $installer -Restore
    Check-Restore
    Write-Host '通过：安装、重复安装、首次备份、中文名称、多语言恢复、UI 文件还原。'
    $policyInitial=$initial.Replace('</oor:items>',@'
<item oor:path="/org.openoffice.Office.Jobs/Jobs/org.openoffice.Office.Jobs:Job['UpdateCheck']/Arguments"><prop oor:name="AutoCheckEnabled" oor:op="fuse"><value>true</value></prop><prop oor:name="AutoDownloadEnabled" oor:op="fuse"><value>true</value></prop></item>
<item oor:path="/org.openoffice.Office.Update/Update"><prop oor:name="Enabled" oor:op="fuse"><value>true</value></prop></item>
</oor:items>
'@)
    [IO.File]::WriteAllText($config,$policyInitial)
    & $installer -Modules Writer -LibreOfficePath $fakeInstall -OnCheck { param($Result) }
    & $installer -Modules Writer -LibreOfficePath $fakeInstall -OnCheck { param($Result) }
    & $installer -Modules Writer -Restore -OnCheck { param($Result) }
    if (Compare-Object (Semantic $policyInitial) (Semantic (Get-Content -LiteralPath $config -Raw -Encoding UTF8))) { throw '官方更新设置的首次值未恢复' }
    [IO.File]::WriteAllText($config,$initial)
    Write-Host '通过：官方提醒、自动下载与 MAR 更新原值恢复、重复配置及带类型路径。'

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
    Write-Host '通过：v3 升级到 v6 后恢复首次配置。'

    # 先单独安装 Draw，再追加两个模块；部分恢复不得覆盖其他模块。
    & $installer -Modules Draw -LibreOfficePath $fakeInstall
    if (!(Test-Path -LiteralPath $drawUi) -or (Test-Path -LiteralPath $calcUi) -or (Get-Content -LiteralPath $writerUi -Raw) -ne $oldUi) { throw '按模块安装修改了其他界面' }
    [xml]$drawOnly=Get-Content -LiteralPath $config -Raw -Encoding UTF8
    if (@($drawOnly.SelectNodes('/*/item/prop') | Where-Object { $_.GetAttribute('name',$ns) -eq 'ActiveCalc' }).Count) { throw 'Draw 安装写入 Calc 设置' }
    if (@($drawOnly.SelectNodes('//value') | Where-Object { $_.InnerText -eq '.uno:FontDialog' }).Count) { throw 'Draw 安装修改 Writer 快捷键' }
    if (!@($drawOnly.SelectNodes('//value') | Where-Object { $_.InnerText -eq '.uno:CustomCalcRight' }).Count -or
        !@($drawOnly.SelectNodes('//value') | Where-Object { $_.InnerText -eq '.uno:FormatUngroup' }).Count) { throw 'Draw 键位未按模块隔离' }
    & $installer -Modules 'Writer,Calc' -LibreOfficePath $fakeInstall
    Simulate-NativeSave
    $writerHash=(Get-FileHash -LiteralPath $writerUi).Hash
    $calcHash=(Get-FileHash -LiteralPath $calcUi).Hash
    & $installer -Modules Draw -Restore
    [xml]$partiallyRestored=Get-Content -LiteralPath $config -Raw -Encoding UTF8
    if (!@($partiallyRestored.SelectNodes('//value') | Where-Object { $_.InnerText -eq '.uno:CustomDrawGroup' }).Count -or
        !@($partiallyRestored.SelectNodes('//value') | Where-Object { $_.InnerText -eq '.uno:FillRight' }).Count) { throw '恢复 Draw 键位修改了 Calc' }
    if ((Test-Path -LiteralPath $drawMenu) -or !(Test-Path -LiteralPath $calcMenu)) { throw '菜单部分恢复范围不正确' }
    if ((Test-Path -LiteralPath $drawUi) -or (Get-FileHash -LiteralPath $writerUi).Hash -ne $writerHash -or (Get-FileHash -LiteralPath $calcUi).Hash -ne $calcHash) { throw '部分恢复修改了其他模块' }
    & $installer -Modules Writer -Restore
    if ((Get-FileHash -LiteralPath $calcUi).Hash -ne $calcHash) { throw '恢复 Writer 修改了 Calc' }
    & $installer -Modules Calc -Restore
    Check-Restore
    Write-Host '通过：独立安装、追加安装、逐模块恢复与共享设置最后恢复。'

    # 三模块 v6 备份结构追加 Impress，首次备份与已有界面必须保留。
    & $installer -Modules 'Writer,Calc,Draw' -LibreOfficePath $fakeInstall
    $writerHash=(Get-FileHash -LiteralPath $writerUi).Hash
    $backupHash=(Get-FileHash -LiteralPath (Join-Path (Split-Path $backup) 'wps-ui-files-backup\swriter.ui')).Hash
    & $installer -Modules Impress -LibreOfficePath $fakeInstall
    if (!(Test-Path -LiteralPath $impressUi) -or !(Test-Path -LiteralPath $impressMenu)) { throw '演示界面或菜单缺失' }
    if ((Get-FileHash -LiteralPath $writerUi).Hash -ne $writerHash -or (Get-FileHash -LiteralPath (Join-Path (Split-Path $backup) 'wps-ui-files-backup\swriter.ui')).Hash -ne $backupHash) { throw '追加演示覆盖已有模块或首次备份' }
    [xml]$withImpress=Get-Content -LiteralPath $config -Raw -Encoding UTF8
    if (!@($withImpress.SelectNodes('//value') | Where-Object { $_.InnerText -eq '.uno:InsertPage' }).Count) { throw '演示键位未配置' }
    & $installer -Modules Impress -Restore
    if ((Get-FileHash -LiteralPath $writerUi).Hash -ne $writerHash) { throw '恢复演示修改文字模块' }
    [xml]$withoutImpress=Get-Content -LiteralPath $config -Raw -Encoding UTF8
    if (!@($withoutImpress.SelectNodes('//value') | Where-Object { $_.InnerText -eq '.uno:CustomImpressKey' }).Count) { throw '演示首次快捷键未还原' }
    if (!@($withoutImpress.SelectNodes('//value') | Where-Object { $_.InnerText -eq 'colibre' }).Count) { throw '部分恢复提前还原共享设置' }
    if (@($withoutImpress.SelectNodes('//prop') | Where-Object { $_.GetAttribute('name',$ns) -eq 'Enabled' })[0].value -ne 'false') { throw '部分恢复提前重新启用自动更新' }
    & $installer -Modules 'Writer,Calc,Draw' -Restore
    Check-Restore
    & $installer -Modules Impress -LibreOfficePath $fakeInstall
    if ((Get-Content -LiteralPath $writerUi -Raw) -ne $oldUi -or (Test-Path -LiteralPath $calcUi) -or (Test-Path -LiteralPath $drawUi)) { throw '演示独立安装影响其他模块' }
    & $installer -Modules Impress -Restore
    Check-Restore
    Write-Host '通过：演示独立安装、三模块升级追加、首次键位与共享设置恢复。'

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
    & $installer -Modules 'Writer,Calc,Impress' -Restore
    Check-Restore
    Write-Host '通过：真实 v4 备份升级到 v6 并分模块恢复。'

    # v5 无 Path 的旧清单仍使用原 notebookbar 备份名，菜单另建首次记录。
    & $installer -Modules Writer -LibreOfficePath $fakeInstall
    & $installer -Modules Writer -Restore
    $statePath=Join-Path $fixture 'LibreOffice\wps-ui-files-backup\state.json'
    [IO.File]::WriteAllText($writerUi,'<interface id="v5"/>')
    [IO.File]::WriteAllText((Join-Path (Split-Path $statePath) 'swriter.ui'),$oldUi)
    '[{"Module":"swriter","Existed":true}]' | Set-Content -LiteralPath $statePath -Encoding UTF8
    '<backup version="5"><tracked/></backup>' | Set-Content -LiteralPath $backup -Encoding UTF8
    & $installer -Modules Writer -LibreOfficePath $fakeInstall
    & $installer -Modules Writer -Restore
    Check-Restore
    Write-Host '通过：v5 旧文件清单升级及原菜单恢复。'

    # 同一份备份经历升级、拒绝混用、降级后仍可恢复；旧清单也需受版本保护。
    $statePath=Join-Path $fixture 'LibreOffice\wps-ui-files-backup\state.json'
    & $installer -LibreOfficePath $fakeInstall
    $firstBackup=(Get-FileHash -LiteralPath $backup).Hash
    $firstUi=(Get-FileHash -LiteralPath (Join-Path (Split-Path $statePath) 'swriter.ui')).Hash
    $legacyState=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    ConvertTo-Json -InputObject @($legacyState | Select-Object Module,Path,Existed) | Set-Content -LiteralPath $statePath -Encoding UTF8
    [IO.File]::WriteAllText("$fakeInstall\program\version.ini",'buildid=bf6ef2662401c7d6dce671ab4deb26ee0af3a7c1')
    $before=(Get-FileHash -LiteralPath $config).Hash
    $stateBefore=(Get-FileHash -LiteralPath $statePath).Hash
    $uiBefore=(Get-FileHash -LiteralPath $writerUi).Hash
    $refused=$false
    try { & $installer -Modules Writer -LibreOfficePath $fakeInstall } catch {
        $refused=$true
        if ($_.Exception.Message -notmatch '软件版本发生变化') { throw }
    }
    if (!$refused -or (Get-FileHash -LiteralPath $config).Hash -ne $before -or (Get-FileHash -LiteralPath $statePath).Hash -ne $stateBefore -or (Get-FileHash -LiteralPath $writerUi).Hash -ne $uiBefore) { throw '混合版本未在写入前停止' }
    function Move-Item {
        param([string]$LiteralPath,[string]$Destination,[switch]$Force)
        if ($Destination -eq $statePath) { throw '模拟版本记录提交失败' }
        Microsoft.PowerShell.Management\Move-Item @PSBoundParameters
    }
    $failed=$false
    try { & $installer -LibreOfficePath $fakeInstall } catch { $failed=$true }
    finally { Remove-Item Function:\Move-Item }
    if (!$failed -or (Get-FileHash -LiteralPath $config).Hash -ne $before -or (Get-FileHash -LiteralPath $writerUi).Hash -ne $uiBefore -or (Get-FileHash -LiteralPath $statePath).Hash -ne $stateBefore) { throw '版本记录失败后未撤回设置、界面和构建记录' }
    foreach ($buildId in 'bf6ef2662401c7d6dce671ab4deb26ee0af3a7c1','cd7284b4cbbfeb507e630c1aac019f4157393acb') {
        [IO.File]::WriteAllText("$fakeInstall\program\version.ini","buildid=$buildId")
        $checks.Clear()
        & $installer -LibreOfficePath $fakeInstall -OnCheck { param($Result) $checks.Add($Result) }
        $variant=if ($buildId -like 'bf6*') { 'package\variants\26.8.1' } else { 'package' }
        $files=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($file in $files) {
            $source=if ($file.Path -eq 'ui/notebookbar.ui') { Join-Path $repo "$variant\ui\$($file.Module)\notebookbar.ui" }
                else { Join-Path $repo "$variant\profile\config\soffice.cfg\modules\$($file.Module)\$($file.Path)" }
            $target=Join-Path $profile "config\soffice.cfg\modules\$($file.Module)\$($file.Path)"
            if ($file.BuildId -cne $buildId -or (Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $target).Hash) { throw '版本专属文件或构建记录不匹配' }
        }
        if ((Get-FileHash -LiteralPath $backup).Hash -ne $firstBackup -or (Get-FileHash -LiteralPath (Join-Path (Split-Path $statePath) 'swriter.ui')).Hash -ne $firstUi) { throw '切换版本覆盖首次备份' }
        if ($buildId -like 'bf6*' -and ($checks | Where-Object { $_.Title -eq '版本兼容' }).Message -notmatch '26.8.1.1') { throw '未显示新版兼容状态' }
    }
    & $installer -Restore
    Check-Restore
    [IO.File]::WriteAllText("$fakeInstall\program\version.ini",'buildid=bf6ef2662401c7d6dce671ab4deb26ee0af3a7c1')
    & $installer -Modules Impress -LibreOfficePath $fakeInstall
    & $installer -Restore -Modules Impress
    Check-Restore
    # 新版专属文件缺失时，不得回退到旧版或创建备份。
    $before=(Get-FileHash -LiteralPath $config).Hash
    $source=Join-Path $repo 'package\variants\26.8.1\ui\swriter\notebookbar.ui'
    [IO.File]::Move($source,"$source.test-saved")
    $refused=$false
    try { & $installer -Modules Writer -LibreOfficePath $fakeInstall } catch { $refused=$true }
    finally { [IO.File]::Move("$source.test-saved",$source) }
    if (!$refused -or (Test-Path -LiteralPath $backup) -or (Get-FileHash -LiteralPath $config).Hash -ne $before) { throw '新版文件缺失时没有安全停止' }
    [IO.File]::WriteAllText("$fakeInstall\program\version.ini",'buildid=cd7284b4cbbfeb507e630c1aac019f4157393acb')
    Write-Host '通过：新版专属文件、升级与降级、旧清单防混用、新版单模块与首次恢复。'

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

    # 前面的 notebookbar 与文字菜单已经写入后，第二类菜单失败也须完整撤回。
    $before = (Get-FileHash -LiteralPath $config).Hash
    function Copy-Item {
        param([string]$LiteralPath,[string]$Destination,[switch]$Force)
        if ($Destination -eq $calcMenu) { throw '模拟菜单写入失败' }
        Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
    }
    $failed=$false
    try { & $installer -LibreOfficePath $fakeInstall } catch { $failed=$true }
    finally { Remove-Item Function:\Copy-Item }
    if (!$failed -or (Get-FileHash -LiteralPath $config).Hash -ne $before) { throw '菜单失败后配置未保持原值' }
    Check-Restore
    & $installer -Restore
    Check-Restore
    Write-Host '通过：菜单写入失败完整撤回并保留恢复能力。'

    [IO.File]::WriteAllText("$fakeInstall\program\version.ini",'buildid=unsupported')
    $before = (Get-FileHash -LiteralPath $config).Hash
    $refused = $false
    $checks.Clear()
    try { & $installer -LibreOfficePath $fakeInstall -OnCheck { param($Result) $checks.Add($Result) } } catch { $refused = $true }
    if (!$refused -or (Get-FileHash -LiteralPath $config).Hash -ne $before) { throw '未阻止不匹配版本' }
    if (($checks | Where-Object { $_.Title -eq '版本兼容' }).State -ne '需处理' -or
        ($checks | Where-Object { $_.Title -eq '目录写入' }).State -ne '未检查' -or (Test-Path -LiteralPath $backup)) { throw '不兼容版本的检查状态或停止时机错误' }

    # ini 构建匹配，但程序版本不同，也不能显示为兼容。
    [IO.File]::WriteAllText("$fakeInstall\program\version.ini",'buildid=cd7284b4cbbfeb507e630c1aac019f4157393acb')
    function Get-Item { param($LiteralPath) [pscustomobject]@{VersionInfo=@{ProductVersion='25.8.0.1'}} }
    $checks.Clear(); $refused=$false
    try { & $installer -LibreOfficePath $fakeInstall -OnCheck { param($Result) $checks.Add($Result) } } catch { $refused=$true }
    finally { Remove-Item Function:\Get-Item }
    $versionRow=$checks | Where-Object { $_.Title -eq '版本兼容' }
    if (!$refused -or $versionRow.State -ne '需处理' -or $versionRow.Message -notmatch '25.8.0.1' -or (Test-Path -LiteralPath $backup)) { throw '程序版本不匹配未阻止或未显示实际版本' }

    # 即使程序被升级或卸载，仍可恢复此前安装的界面。
    [IO.File]::WriteAllText("$fakeInstall\program\version.ini",'buildid=cd7284b4cbbfeb507e630c1aac019f4157393acb')
    & $installer -LibreOfficePath $fakeInstall -OnCheck { param($Result) }
    $checks.Clear()
    & $installer -Restore -LibreOfficePath (Join-Path $fixture 'removed-app') -OnCheck { param($Result) $checks.Add($Result) }
    if (($checks | Where-Object { $_.Title -eq '版本兼容' }).State -ne '不适用') { throw '恢复不应要求版本兼容' }
    Check-Restore

    $checks.Clear(); $refused=$false
    try { & $installer -LibreOfficePath (Join-Path $fixture 'missing-app') -OnCheck { param($Result) $checks.Add($Result) } } catch { $refused=$true }
    if (!$refused -or ($checks | Where-Object { $_.Title -eq '安装目录' }).State -ne '需处理') { throw '缺失程序未报告' }

    foreach ($badConfig in @('', '<broken>')) {
        [IO.File]::WriteAllText($config,$badConfig)
        $checks.Clear(); $refused=$false
        try { & $installer -LibreOfficePath $fakeInstall -OnCheck { param($Result) $checks.Add($Result) } } catch { $refused=$true }
        if (!$refused -or ($checks | Where-Object { $_.Title -eq '用户配置' }).State -ne '需处理' -or (Test-Path -LiteralPath $backup)) { throw '无效用户配置未安全停止' }
        if ((Get-Content -LiteralPath $config -Raw) -ne $badConfig -and $badConfig) { throw '无效用户配置被修改' }
    }
    [IO.File]::WriteAllText($config,$initial,[Text.UTF8Encoding]::new($false))
    $before = (Get-FileHash -LiteralPath $config).Hash
    function Get-Process { param($Name,$ErrorAction) [pscustomobject]@{ ProcessName='soffice' } }
    $refused = $false
    $checks.Clear()
    try { & $installer -Restore -OnCheck { param($Result) $checks.Add($Result) } } catch { $refused = $true }
    if (!$refused -or (Get-FileHash -LiteralPath $config).Hash -ne $before) { throw '运行中防护未生效' }
    if (($checks | Where-Object { $_.Title -eq '运行状态' }).State -ne '需处理') { throw '运行中状态未显示' }
    Write-Host '通过：版本、程序缺失、配置损坏和运行状态提示，恢复不受安装版本限制。'
} finally {
    $env:APPDATA = $originalAppData
    Remove-Item Function:\Get-Process -ErrorAction SilentlyContinue
    # 测试目录保留用于故障诊断，.gitignore 排除；不递归删除任何用户目录。
}
