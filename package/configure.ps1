param([switch]$Restore, [string]$Modules = 'Writer,Calc,Draw,Impress',
      [string]$LibreOfficePath = (Join-Path $env:ProgramFiles 'LibreOffice'),
      [scriptblock]$OnProgress = { param($Percent, $Message) },
      [scriptblock]$OnCheck = { param($Result) Write-Host "[$($Result.State)] $($Result.Title)：$($Result.Message)" })
$ErrorActionPreference = 'Stop'
& $OnProgress 5 '正在检查环境与所选模块…'
$moduleIds = @{ Writer='swriter'; Calc='scalc'; Draw='sdraw'; Impress='simpress' }
$moduleNames = @{ swriter='文字'; scalc='表格'; sdraw='绘图'; simpress='演示' }
$selected = @($Modules.Split(',') | ForEach-Object { $_.Trim() } | Select-Object -Unique)
if (!$selected.Count -or @($selected | Where-Object { !$moduleIds.ContainsKey($_) }).Count) {
    & $OnCheck @{Title='所选模块';State='需处理';Message='只接受 Writer、Calc、Draw、Impress，多个模块用英文逗号分隔。'}
    throw 'Modules 只接受 Writer、Calc、Draw、Impress，多个模块用英文逗号分隔。'
}
$selectedIds = @($selected | ForEach-Object { $moduleIds[$_] })
$base = Join-Path $env:APPDATA 'LibreOffice'
$config = Join-Path $base '4\user\registrymodifications.xcu'
$backup = Join-Path $base 'wps-ui-backup.xml'
$uiBackup = Join-Path $base 'wps-ui-files-backup'
$uiState = Join-Path $uiBackup 'state.json'
$ns = 'http://openoffice.org/2001/registry'
$checkFailures = [Collections.Generic.List[string]]::new()
function Check($title, $status, $message) {
    & $OnCheck @{Title=$title;State=$status;Message=$message}
    if ($status -eq '需处理') { $checkFailures.Add($message) }
}
if ($env:OS -eq 'Windows_NT' -and $PSVersionTable.PSVersion -ge [version]'5.1') {
    Check '运行环境' '通过' "Windows · PowerShell $($PSVersionTable.PSVersion)"
} else { Check '运行环境' '需处理' '请在 Windows 中使用 PowerShell 5.1 或更高版本运行配置包。' }
$executable = Join-Path $LibreOfficePath 'program\soffice.exe'
$versionFile = Join-Path $LibreOfficePath 'program\version.ini'
$applicationFound = (Test-Path -LiteralPath $executable -PathType Leaf) -and (Test-Path -LiteralPath $versionFile -PathType Leaf)
if ($Restore) {
    Check '安装目录' '不适用' '恢复仅还原用户配置，不要求软件仍安装在原目录。'
    Check '版本兼容' '不适用' '恢复原界面无需匹配适配版本。'
} else {
    if ($applicationFound) { Check '安装目录' '通过' $LibreOfficePath }
    else { Check '安装目录' '需处理' "未找到完整的 LibreOffice 安装：$LibreOfficePath。请先安装软件；自定义路径请使用 LibreOfficePath 参数。" }
    try {
        $build = if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
            (Get-Content -LiteralPath $versionFile -Encoding UTF8 | Where-Object { $_ -match '^buildid=' }) -replace '^buildid=',''
        }
        $detectedVersion = if (Test-Path -LiteralPath $executable -PathType Leaf) { (Get-Item -LiteralPath $executable).VersionInfo.ProductVersion }
        $buildMatches = $applicationFound -and $build -ceq 'cd7284b4cbbfeb507e630c1aac019f4157393acb'
        $compatible = $buildMatches -and (!$detectedVersion -or $detectedVersion -eq '26.2.5.2')
        if (!$detectedVersion) { $detectedVersion = if ($buildMatches) { '26.2.5.2' } else { '无法识别' } }
        if ($compatible) { Check '版本兼容' '通过' "当前 $detectedVersion · 适配 26.2.5.2，构建匹配。" }
        else { Check '版本兼容' '需处理' "当前版本：$detectedVersion；本包适配 LibreOffice 26.2.5.2，且须匹配验证过的构建。请使用适配版本或等待对应版本配置包。" }
    } catch { Check '版本兼容' '需处理' "无法读取版本信息：$($_.Exception.Message)。请检查安装文件和读取权限。" }
}
if (Get-Process -Name 'soffice','soffice.bin' -ErrorAction SilentlyContinue) {
    Check '运行状态' '需处理' '请先保存文档并完全退出 LibreOffice，再运行此配置包。不会强制结束进程。'
} else { Check '运行状态' '通过' 'LibreOffice 已退出，可以处理用户配置。' }
try {
    if (!(Test-Path -LiteralPath $config -PathType Leaf)) { throw '请先启动并关闭一次 LibreOffice，生成用户配置。' }
    [xml]$doc = Get-Content -LiteralPath $config -Raw -Encoding UTF8
    if ($doc.DocumentElement.LocalName -ne 'items') { throw '用户配置格式不正确，请修复 LibreOffice 用户配置后重试。' }
    Check '用户配置' '通过' '已找到并读取当前用户配置。'
} catch { Check '用户配置' '需处理' $_.Exception.Message }
if (!$checkFailures.Count) {
    $probe = Join-Path (Split-Path $config) ('.wps-check-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $stream = [IO.File]::Open($probe,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $stream.Dispose()
        [IO.File]::Delete($probe)
        Check '目录写入' '通过' '当前用户配置目录可写，临时检查文件已清理。'
    } catch { Check '目录写入' '需处理' "无法写入或清理用户配置目录的检查文件：$($_.Exception.Message)。请检查目录权限或安全软件的拦截记录。" }
    finally { if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -ErrorAction SilentlyContinue } }
} else { Check '目录写入' '未检查' '前置检查未通过，尚未测试写入权限。' }
if ($checkFailures.Count) { throw ($checkFailures -join "`n") }
& $OnProgress 15 '已读取当前用户配置，正在检查配置包…'
function Scope($path, $name) {
    if ($path -match 'Writer|com.sun.star.text.TextDocument' -or $name -eq 'ActiveWriter') { return 'Writer' }
    if ($path -match 'Calc|com.sun.star.sheet.SpreadsheetDocument' -or $name -eq 'ActiveCalc') { return 'Calc' }
    if ($path -match 'Draw|com.sun.star.drawing.DrawingDocument' -or $name -eq 'ActiveDraw') { return 'Draw' }
    if ($path -match 'Impress|com.sun.star.presentation.PresentationDocument' -or $name -eq 'ActiveImpress') { return 'Impress' }
    return 'Shared'
}
function Canonical-Path($path) {
    # LibreOffice 保存后会将集合节点改写为带类型的选择器，两种形式表示同一节点。
    [regex]::Replace($path, "[^/:\[\]]+:[^/:\[\]]+\['([^']*)'\]", '$1')
}
function Find-Settings($xml, $path, $name) {
    $canonical = Canonical-Path $path
    foreach ($item in @($xml.DocumentElement.SelectNodes('item'))) {
        $itemPath = Canonical-Path ($item.GetAttribute('path',$ns))
        # 新建快捷键保存为模块 item 下的 Key 集合节点，统一成单键 item 读取和备份。
        foreach ($keyNode in @($item.SelectNodes('node'))) {
            if ("$itemPath/$($keyNode.GetAttribute('name',$ns))" -ne $canonical) { continue }
            $replacement=$xml.CreateElement('item'); $replacement.SetAttribute('path',$ns,$canonical) | Out-Null
            foreach ($property in @($keyNode.SelectNodes('prop'))) { $replacement.AppendChild($property.CloneNode($true)) | Out-Null }
            $xml.DocumentElement.AppendChild($replacement) | Out-Null
            $item.RemoveChild($keyNode) | Out-Null
            if (!$item.HasChildNodes) { $xml.DocumentElement.RemoveChild($item) | Out-Null }
            $item=$replacement; $itemPath=$canonical
        }
        # 本地化属性会保存为 item 路径末尾的属性名与直属 value，统一成 prop 形式再处理。
        if ($itemPath -eq "$canonical/$name" -and @($item.SelectNodes('value')).Count) {
            $replacement = $xml.CreateElement('item'); $replacement.SetAttribute('path',$ns,$canonical) | Out-Null
            $property = $xml.CreateElement('prop'); $property.SetAttribute('name',$ns,$name) | Out-Null
            $property.SetAttribute('op',$ns,'fuse') | Out-Null
            foreach ($value in @($item.SelectNodes('value'))) { $property.AppendChild($value.CloneNode($true)) | Out-Null }
            $replacement.AppendChild($property) | Out-Null
            $xml.DocumentElement.ReplaceChild($replacement,$item) | Out-Null
            $item=$replacement; $itemPath=$canonical
        }
        if ($itemPath -eq $canonical -and @($item.SelectNodes('prop') | Where-Object { $_.GetAttribute('name',$ns) -eq $name }).Count) { $item }
    }
}
function Append-Setting($xml, $item) {
    $path=Canonical-Path ($item.GetAttribute('path',$ns))
    if ($path -match '^(/org.openoffice.Office.Accelerators/PrimaryKeys/Modules/[^/]+)/([^/]+)$') {
        $container=$xml.CreateElement('item'); $container.SetAttribute('path',$ns,$Matches[1]) | Out-Null
        $keyNode=$xml.CreateElement('node'); $keyNode.SetAttribute('name',$ns,$Matches[2]) | Out-Null
        $keyNode.SetAttribute('op',$ns,'replace') | Out-Null
        foreach ($property in @($item.SelectNodes('prop'))) { $keyNode.AppendChild($property.CloneNode($true)) | Out-Null }
        $container.AppendChild($keyNode) | Out-Null; $item=$container
    }
    $xml.DocumentElement.AppendChild($item) | Out-Null
}
function Remove-Setting($xml, $path, $name) {
    foreach ($item in (Find-Settings $xml $path $name)) {
        foreach ($prop in @($item.ChildNodes)) {
            if ($prop.LocalName -eq 'prop' -and $prop.GetAttribute('name',$ns) -eq $name) { $item.RemoveChild($prop) | Out-Null }
        }
        if (!$item.HasChildNodes) { $xml.DocumentElement.RemoveChild($item) | Out-Null }
    }
}
function UiPath($module, $path = 'ui/notebookbar.ui') { Join-Path $base "4\user\config\soffice.cfg\modules\$module\$path" }
function FileKey($entry) {
    if ($entry.Path -eq 'ui/notebookbar.ui') { return "$($entry.Module).ui" }
    return "$($entry.Module)-$([IO.Path]::GetFileName($entry.Path))"
}
function Valid-File($entry) {
    $entry.Module -in $moduleIds.Values -and ($entry.Path -eq 'ui/notebookbar.ui' -or $entry.Path -cmatch '^popupmenu/[a-z0-9_]+\.xml$')
}
$packageFiles = @($selectedIds | ForEach-Object { [pscustomobject]@{Module=$_;Path='ui/notebookbar.ui'} })
try {
$menuFiles = ConvertFrom-Json -InputObject (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'profile-files.json') -Raw -Encoding UTF8)
foreach ($file in $menuFiles) {
    $prefix = "config/soffice.cfg/modules/$($file.Module)/"
    if (!$file.Path.StartsWith($prefix)) { throw '菜单文件路径不正确，未修改设置。' }
    $entry = [pscustomobject]@{Module=$file.Module;Path=$file.Path.Substring($prefix.Length)}
    if (!(Valid-File $entry)) { throw '菜单文件路径不正确，未修改设置。' }
    if ($entry.Module -in $selectedIds) { $packageFiles += $entry }
}
# 前十二项固定，供 v1-v3 备份迁移。
$defaults = @(
    @('/org.openoffice.Office.UI.ToolbarMode','ActiveWriter','notebookbar.ui'),
    @('/org.openoffice.Office.UI.ToolbarMode','ActiveCalc','notebookbar.ui'),
    @("/org.openoffice.Office.UI.ToolbarMode/Applications/org.openoffice.Office.UI.ToolbarMode:Application['Writer']",'Active','notebookbar.ui'),
    @("/org.openoffice.Office.UI.ToolbarMode/Applications/org.openoffice.Office.UI.ToolbarMode:Application['Calc']",'Active','notebookbar.ui'),
    @('/org.openoffice.Office.Common/Misc','SymbolStyle','colibre'),
    @('/org.openoffice.Office.Common/Misc','NotebookbarIconSize','1'),
    @('/org.openoffice.Office.Calc/Layout/Line','GridLine','true'),
    @('/org.openoffice.Office.Calc/Layout/Window','ColumnRowHeader','true'),
    @('/org.openoffice.Office.Calc/Layout/Window','SheetTab','true'),
    @('/org.openoffice.Office.Writer/Layout/Window','ShowRulers','false'),
    @('/org.openoffice.Office.UI.ToolbarMode/Applications/Writer/Modes/Tabbed','Sidebar','Opened'),
    @('/org.openoffice.Office.UI.ToolbarMode/Applications/Calc/Modes/Tabbed','Sidebar','Arrow'),
    @('/org.openoffice.Office.UI.ToolbarMode','ActiveDraw','notebookbar.ui'),
    @("/org.openoffice.Office.UI.ToolbarMode/Applications/org.openoffice.Office.UI.ToolbarMode:Application['Draw']",'Active','notebookbar.ui'),
    @('/org.openoffice.Office.UI.ToolbarMode/Applications/Draw/Modes/Tabbed','Sidebar','Opened'),
    @('/org.openoffice.Office.UI.ToolbarMode','ActiveImpress','notebookbar.ui'),
    @("/org.openoffice.Office.UI.ToolbarMode/Applications/org.openoffice.Office.UI.ToolbarMode:Application['Impress']",'Active','notebookbar.ui'),
    @('/org.openoffice.Office.UI.ToolbarMode/Applications/Impress/Modes/Tabbed','Sidebar','Opened'),
    @('/org.openoffice.Office.Impress/MultiPaneGUI/SlideSorterBar/Visible','ImpressView','true')
)
$changes = @($defaults | Where-Object { (Scope $_[0] $_[1]) -in ($selected + 'Shared') })
$labels = ConvertFrom-Json -InputObject (Get-Content -LiteralPath (Join-Path $PSScriptRoot '设置清单.json') -Raw -Encoding UTF8)
foreach ($setting in $labels) {
    if ((Scope $setting.Path $setting.Name) -in ($selected + 'Shared')) { $changes += ,@($setting.Path,$setting.Name,$setting.Value,$setting.Localized,$setting.Language) }
}
if (!$Restore) {
    foreach ($file in $packageFiles | Where-Object { $_.Path -like 'popupmenu/*' }) {
        [xml]$menuCheck = Get-Content -LiteralPath (Join-Path $PSScriptRoot "profile/config/soffice.cfg/modules/$($file.Module)/$($file.Path)") -Raw -Encoding UTF8
        if ($menuCheck.DocumentElement.LocalName -ne 'menupopup' -or $menuCheck.DocumentElement.NamespaceURI -ne 'http://openoffice.org/2001/menu') { throw '菜单文件不完整，未修改设置。' }
    }
    foreach ($module in $selectedIds) {
        [xml]$uiCheck = Get-Content -LiteralPath (Join-Path $PSScriptRoot "ui\$module\notebookbar.ui") -Raw -Encoding UTF8
        if (!$uiCheck.SelectSingleNode('//object[@id="ContextContainer"]')) { throw '功能区文件不完整，未修改设置。' }
    }
}
Check '配置包文件' '通过' $(if ($Restore) { '恢复所需清单已读取。' } else { '所选模块的功能区、菜单和设置清单已校验。' })
} catch { Check '配置包文件' '需处理' "配置包不完整或格式不正确：$($_.Exception.Message)。请重新解压完整 ZIP。"; throw }
try {
$uiFiles = @()
& $OnProgress 30 '正在核对首次备份与恢复记录…'
if (Test-Path -LiteralPath $uiState) {
    $uiFiles = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $uiState -Raw -Encoding UTF8)
    if ($uiFiles -isnot [array]) { $uiFiles = @($uiFiles) }
    foreach ($entry in $uiFiles) {
        # v4/v5 的清单只记录 Module，首次 notebookbar 备份文件名保持不变。
        if (!$entry.PSObject.Properties['Path']) { $entry | Add-Member -NotePropertyName Path -NotePropertyValue 'ui/notebookbar.ui' }
    }
    $keys = @($uiFiles | ForEach-Object { "$($_.Module)/$($_.Path)" })
    if ($uiFiles.Count -lt 1 -or $uiFiles.Count -gt 128 -or @($keys | Sort-Object -Unique).Count -ne $uiFiles.Count -or
        @($uiFiles | Where-Object { !(Valid-File $_) -or $_.Existed -isnot [bool] }).Count) { throw '界面备份清单格式不正确，未修改设置。' }
    foreach ($entry in $uiFiles) {
        if ($entry.Existed -and !(Test-Path -LiteralPath (Join-Path $uiBackup (FileKey $entry)))) { throw '原界面备份文件缺失，未修改设置。' }
    }
}
$saved = New-Object System.Xml.XmlDocument
if (Test-Path -LiteralPath $backup) {
    $saved.Load($backup); $version = $saved.DocumentElement.GetAttribute('version')
    if ($saved.DocumentElement.Name -ne 'backup' -or $version -notin @('1','2','3','4','5','6')) { throw '无法识别配置备份版本，未修改设置。' }
} elseif ($Restore) { throw '没有找到此配置包的备份。' }
else { $saved.LoadXml('<backup version="6"><tracked/></backup>'); $version='6' }
Check '首次备份' '通过' $(if (Test-Path -LiteralPath $backup) { '已找到并校验原备份，将继续保留首次记录。' } else { '未发现旧备份，本次安装将创建首次备份。' })
} catch { Check '首次备份' '需处理' $_.Exception.Message; throw }
$tracked = $saved.SelectSingleNode('/backup/tracked')
if (!$tracked) {
    $tracked = $saved.CreateElement('tracked'); $saved.DocumentElement.AppendChild($tracked) | Out-Null
    foreach ($setting in @($defaults | Select-Object -First $(if ($version -in @('2','3')) { 12 } else { 5 }))) {
        $node = $saved.CreateElement('setting'); $node.SetAttribute('path',$setting[0]); $node.SetAttribute('name',$setting[1]); $tracked.AppendChild($node) | Out-Null
    }
}
foreach ($node in $tracked.SelectNodes('setting')) { $node.SetAttribute('scope',(Scope $node.path $node.name)) }
$saved.DocumentElement.SetAttribute('version','6')
if ($Restore) {
    $remaining = @($uiFiles | Where-Object { $_.Module -notin $selectedIds })
    $scopes = $selected + $(if (!$remaining.Count) { 'Shared' })
    $changes = @($tracked.SelectNodes('setting') | Where-Object { $_.scope -in $scopes } | ForEach-Object { ,@($_.path,$_.name) })
    $applyUi = @($uiFiles | Where-Object { $_.Module -in $selectedIds })
    if (!$changes.Count -and !$applyUi.Count) { throw '所选模块没有本包安装记录。' }
} else {
    foreach ($change in $changes) {
        if (!@($tracked.SelectNodes('setting') | Where-Object { $_.path -eq $change[0] -and $_.name -eq $change[1] }).Count) {
            foreach ($item in (Find-Settings $doc $change[0] $change[1])) {
                $copy = $saved.ImportNode($item,$true)
                foreach ($prop in @($copy.ChildNodes)) { if ($prop.GetAttribute('name',$ns) -ne $change[1]) { $copy.RemoveChild($prop) | Out-Null } }
                $saved.DocumentElement.AppendChild($copy) | Out-Null
            }
            $node = $saved.CreateElement('setting'); $node.SetAttribute('path',$change[0]); $node.SetAttribute('name',$change[1]); $node.SetAttribute('scope',(Scope $change[0] $change[1])); $tracked.AppendChild($node) | Out-Null
        }
    }
    New-Item -ItemType Directory -Path $uiBackup -Force | Out-Null
    foreach ($entry in $packageFiles) {
        if (!@($uiFiles | Where-Object { $_.Module -eq $entry.Module -and $_.Path -eq $entry.Path }).Count) {
            $target = UiPath $entry.Module $entry.Path; $existed = Test-Path -LiteralPath $target
            if ($existed) { Copy-Item -LiteralPath $target -Destination (Join-Path $uiBackup (FileKey $entry)) -Force }
            $uiFiles += [pscustomobject]@{ Module=$entry.Module; Path=$entry.Path; Existed=$existed }
        }
    }
    $saved.Save($backup)
    ConvertTo-Json -InputObject @($uiFiles) | Set-Content -LiteralPath $uiState -Encoding UTF8
    $applyUi = @($uiFiles | Where-Object { $_.Module -in $selectedIds })
}
foreach ($change in $changes) {
    Remove-Setting $doc $change[0] $change[1]
    if ($Restore) {
        foreach ($item in (Find-Settings $saved $change[0] $change[1])) {
            $copy=$doc.ImportNode($item,$true)
            foreach ($prop in @($copy.ChildNodes)) { if ($prop.GetAttribute('name',$ns) -ne $change[1]) { $copy.RemoveChild($prop) | Out-Null } }
            Append-Setting $doc $copy
        }
    } else {
        $item = $doc.CreateElement('item'); $item.SetAttribute('path',$ns,$change[0]) | Out-Null
        $prop = $doc.CreateElement('prop'); $prop.SetAttribute('name',$ns,$change[1]) | Out-Null; $prop.SetAttribute('op',$ns,'fuse') | Out-Null
        $value = $doc.CreateElement('value'); $value.InnerText = $change[2]
        if ($change.Count -gt 3 -and $change[3]) {
            $lang = $doc.CreateAttribute('xml','lang','http://www.w3.org/XML/1998/namespace')
            $lang.Value = if ($change.Count -gt 4 -and $change[4]) { $change[4] } else { 'zh-CN' }
            $value.Attributes.Append($lang) | Out-Null
        }
        $prop.AppendChild($value) | Out-Null; $item.AppendChild($prop) | Out-Null; Append-Setting $doc $item
    }
}
$temp = "$config.wps-ui.tmp"; $doc.Save($temp)
& $OnProgress 55 '已准备好设置，正在保护现有界面…'
[xml]$verified = Get-Content -LiteralPath $temp -Raw -Encoding UTF8
$stage = Join-Path $base ('wps-ui-stage-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
$current = @{}
foreach ($entry in $applyUi) {
    $key=FileKey $entry; $target=UiPath $entry.Module $entry.Path; $current[$key]=Test-Path -LiteralPath $target
    if ($current[$key]) { Copy-Item -LiteralPath $target -Destination (Join-Path $stage $key) }
}
try {
    $completedUi = 0
    foreach ($entry in $applyUi) {
        & $OnProgress (60 + [int](25 * $completedUi / [Math]::Max(1,$applyUi.Count))) "正在处理$($moduleNames[$entry.Module])界面…"
        $target=UiPath $entry.Module $entry.Path
        if (!$Restore -or $entry.Existed) {
            $source = if ($Restore) { Join-Path $uiBackup (FileKey $entry) }
                elseif ($entry.Path -eq 'ui/notebookbar.ui') { Join-Path $PSScriptRoot "ui\$($entry.Module)\notebookbar.ui" }
                else { Join-Path $PSScriptRoot "profile/config/soffice.cfg/modules/$($entry.Module)/$($entry.Path)" }
            New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $target -Force
        } elseif (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target }
        $completedUi++
    }
    & $OnProgress 90 '正在保存设置…'
    Move-Item -LiteralPath $temp -Destination $config -Force
} catch {
    foreach ($entry in $applyUi) {
        $key=FileKey $entry; $target=UiPath $entry.Module $entry.Path
        if ($current[$key]) { Copy-Item -LiteralPath (Join-Path $stage $key) -Destination $target -Force }
        elseif (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target }
    }
    throw
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp }
    foreach ($entry in $applyUi) {
        $file=Join-Path $stage (FileKey $entry)
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
    }
    Remove-Item -LiteralPath $stage
}
& $OnProgress 95 '正在整理恢复记录与临时文件…'
if ($Restore) {
    foreach ($change in $changes) {
        Remove-Setting $saved $change[0] $change[1]
        foreach ($node in @($tracked.SelectNodes('setting') | Where-Object { $_.path -eq $change[0] -and $_.name -eq $change[1] })) { $tracked.RemoveChild($node) | Out-Null }
    }
    foreach ($entry in $applyUi) {
        $file=Join-Path $uiBackup (FileKey $entry)
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
    }
    if ($remaining.Count -or $tracked.HasChildNodes) {
        $saved.Save($backup); ConvertTo-Json -InputObject @($remaining) | Set-Content -LiteralPath $uiState -Encoding UTF8
    } else {
        Remove-Item -LiteralPath $backup
        if (Test-Path -LiteralPath $uiState) { Remove-Item -LiteralPath $uiState }
    }
    Write-Host "已恢复模块：$($selected -join '、')。"
} else { Write-Host "已安装 LibreOfficePlus：$($selected -join '、')。请重新打开所选模块。" }
& $OnProgress 100 '所有步骤已完成。'
