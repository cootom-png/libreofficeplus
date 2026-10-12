param([switch]$Restore, [string]$Modules = 'Writer,Calc,Draw',
      [string]$LibreOfficePath = (Join-Path $env:ProgramFiles 'LibreOffice'))
$ErrorActionPreference = 'Stop'
$moduleIds = @{ Writer='swriter'; Calc='scalc'; Draw='sdraw' }
$selected = @($Modules.Split(',') | ForEach-Object { $_.Trim() } | Select-Object -Unique)
if (!$selected.Count -or @($selected | Where-Object { !$moduleIds.ContainsKey($_) }).Count) { throw 'Modules 只接受 Writer、Calc、Draw，多个模块用英文逗号分隔。' }
$selectedIds = @($selected | ForEach-Object { $moduleIds[$_] })
$base = Join-Path $env:APPDATA 'LibreOffice'
$config = Join-Path $base '4\user\registrymodifications.xcu'
$backup = Join-Path $base 'wps-ui-backup.xml'
$uiBackup = Join-Path $base 'wps-ui-files-backup'
$uiState = Join-Path $uiBackup 'state.json'
$ns = 'http://openoffice.org/2001/registry'
if (Get-Process -Name 'soffice','soffice.bin' -ErrorAction SilentlyContinue) { throw '请先保存文档并完全退出 LibreOffice，再运行此配置包。不会强制结束进程。' }
if (!(Test-Path -LiteralPath $config)) { throw '请先启动并关闭一次 LibreOffice，生成用户配置。' }
[xml]$doc = Get-Content -LiteralPath $config -Raw -Encoding UTF8
function Scope($path, $name) {
    if ($path -match 'Writer|com.sun.star.text.TextDocument' -or $name -eq 'ActiveWriter') { return 'Writer' }
    if ($path -match 'Calc' -or $name -eq 'ActiveCalc') { return 'Calc' }
    if ($path -match 'Draw' -or $name -eq 'ActiveDraw') { return 'Draw' }
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
function Remove-Setting($xml, $path, $name) {
    foreach ($item in (Find-Settings $xml $path $name)) {
        foreach ($prop in @($item.ChildNodes)) {
            if ($prop.LocalName -eq 'prop' -and $prop.GetAttribute('name',$ns) -eq $name) { $item.RemoveChild($prop) | Out-Null }
        }
        if (!$item.HasChildNodes) { $xml.DocumentElement.RemoveChild($item) | Out-Null }
    }
}
function UiPath($module) { Join-Path $base "4\user\config\soffice.cfg\modules\$module\ui\notebookbar.ui" }
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
    @('/org.openoffice.Office.UI.ToolbarMode/Applications/Draw/Modes/Tabbed','Sidebar','Opened')
)
$changes = @($defaults | Where-Object { (Scope $_[0] $_[1]) -in ($selected + 'Shared') })
$labels = ConvertFrom-Json -InputObject (Get-Content -LiteralPath (Join-Path $PSScriptRoot '设置清单.json') -Raw -Encoding UTF8)
foreach ($setting in $labels) {
    if ((Scope $setting.Path $setting.Name) -in ($selected + 'Shared')) { $changes += ,@($setting.Path,$setting.Name,$setting.Value,$setting.Localized,$setting.Language) }
}
if (!$Restore) {
    $versionFile = Join-Path $LibreOfficePath 'program\version.ini'
    if (!(Test-Path -LiteralPath $versionFile) -or !(Select-String -LiteralPath $versionFile -Pattern '^buildid=cd7284b4cbbfeb507e630c1aac019f4157393acb$' -Quiet)) { throw '本定制功能区只验证用于 LibreOffice 26.2.5.2，未修改设置。' }
    foreach ($module in $selectedIds) {
        [xml]$uiCheck = Get-Content -LiteralPath (Join-Path $PSScriptRoot "ui\$module\notebookbar.ui") -Raw -Encoding UTF8
        if (!$uiCheck.SelectSingleNode('//object[@id="ContextContainer"]')) { throw '功能区文件不完整，未修改设置。' }
    }
}
$uiFiles = @()
if (Test-Path -LiteralPath $uiState) {
    $uiFiles = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $uiState -Raw -Encoding UTF8)
    if ($uiFiles -isnot [array]) { $uiFiles = @($uiFiles) }
    if ($uiFiles.Count -lt 1 -or $uiFiles.Count -gt 3 -or @($uiFiles.Module | Sort-Object -Unique).Count -ne $uiFiles.Count -or
        @($uiFiles | Where-Object { $_.Module -notin $moduleIds.Values -or $_.Existed -isnot [bool] }).Count) { throw '界面备份清单格式不正确，未修改设置。' }
    foreach ($entry in $uiFiles) {
        if ($entry.Existed -and !(Test-Path -LiteralPath (Join-Path $uiBackup "$($entry.Module).ui"))) { throw '原界面备份文件缺失，未修改设置。' }
    }
}
$saved = New-Object System.Xml.XmlDocument
if (Test-Path -LiteralPath $backup) {
    $saved.Load($backup); $version = $saved.DocumentElement.GetAttribute('version')
    if ($saved.DocumentElement.Name -ne 'backup' -or $version -notin @('1','2','3','4','5')) { throw '无法识别配置备份版本，未修改设置。' }
} elseif ($Restore) { throw '没有找到此配置包的备份。' }
else { $saved.LoadXml('<backup version="5"><tracked/></backup>'); $version='5' }
$tracked = $saved.SelectSingleNode('/backup/tracked')
if (!$tracked) {
    $tracked = $saved.CreateElement('tracked'); $saved.DocumentElement.AppendChild($tracked) | Out-Null
    foreach ($setting in @($defaults | Select-Object -First $(if ($version -in @('2','3')) { 12 } else { 5 }))) {
        $node = $saved.CreateElement('setting'); $node.SetAttribute('path',$setting[0]); $node.SetAttribute('name',$setting[1]); $tracked.AppendChild($node) | Out-Null
    }
}
foreach ($node in $tracked.SelectNodes('setting')) { $node.SetAttribute('scope',(Scope $node.path $node.name)) }
$saved.DocumentElement.SetAttribute('version','5')
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
    foreach ($module in $selectedIds) {
        if ($module -notin $uiFiles.Module) {
            $target = UiPath $module; $existed = Test-Path -LiteralPath $target
            if ($existed) { Copy-Item -LiteralPath $target -Destination (Join-Path $uiBackup "$module.ui") -Force }
            $uiFiles += [pscustomobject]@{ Module=$module; Existed=$existed }
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
            $doc.DocumentElement.AppendChild($copy) | Out-Null
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
        $prop.AppendChild($value) | Out-Null; $item.AppendChild($prop) | Out-Null; $doc.DocumentElement.AppendChild($item) | Out-Null
    }
}
$temp = "$config.wps-ui.tmp"; $doc.Save($temp)
[xml]$verified = Get-Content -LiteralPath $temp -Raw -Encoding UTF8
$stage = Join-Path $base ('wps-ui-stage-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
$current = @{}
foreach ($entry in $applyUi) {
    $module=$entry.Module; $target=UiPath $module; $current[$module]=Test-Path -LiteralPath $target
    if ($current[$module]) { Copy-Item -LiteralPath $target -Destination (Join-Path $stage "$module.ui") }
}
try {
    foreach ($entry in $applyUi) {
        $target=UiPath $entry.Module
        if (!$Restore -or $entry.Existed) {
            $source = if ($Restore) { Join-Path $uiBackup "$($entry.Module).ui" } else { Join-Path $PSScriptRoot "ui\$($entry.Module)\notebookbar.ui" }
            New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $target -Force
        } elseif (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target }
    }
    Move-Item -LiteralPath $temp -Destination $config -Force
} catch {
    foreach ($entry in $applyUi) {
        $module=$entry.Module; $target=UiPath $module
        if ($current[$module]) { Copy-Item -LiteralPath (Join-Path $stage "$module.ui") -Destination $target -Force }
        elseif (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target }
    }
    throw
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp }
    foreach ($entry in $applyUi) {
        $file=Join-Path $stage "$($entry.Module).ui"
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
    }
    Remove-Item -LiteralPath $stage
}
if ($Restore) {
    foreach ($change in $changes) {
        Remove-Setting $saved $change[0] $change[1]
        foreach ($node in @($tracked.SelectNodes('setting') | Where-Object { $_.path -eq $change[0] -and $_.name -eq $change[1] })) { $tracked.RemoveChild($node) | Out-Null }
    }
    foreach ($entry in $applyUi) {
        $file=Join-Path $uiBackup "$($entry.Module).ui"
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
    }
    if ($remaining.Count -or $tracked.HasChildNodes) {
        $saved.Save($backup); ConvertTo-Json -InputObject @($remaining) | Set-Content -LiteralPath $uiState -Encoding UTF8
    } else {
        Remove-Item -LiteralPath $backup
        if (Test-Path -LiteralPath $uiState) { Remove-Item -LiteralPath $uiState }
    }
    Write-Host "已恢复模块：$($selected -join '、')。"
} else { Write-Host "已安装 LibreOfficePlus v5：$($selected -join '、')。请重新打开所选模块。" }
