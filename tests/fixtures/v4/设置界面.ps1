param([switch]$Restore, [string]$LibreOfficePath = (Join-Path $env:ProgramFiles 'LibreOffice'))
$ErrorActionPreference = 'Stop'
$config = Join-Path $env:APPDATA 'LibreOffice\4\user\registrymodifications.xcu'
$backup = Join-Path $env:APPDATA 'LibreOffice\wps-ui-backup.xml'
$ns = 'http://openoffice.org/2001/registry'
if (Get-Process -Name 'soffice','soffice.bin' -ErrorAction SilentlyContinue) {
    throw '请先保存文档并完全退出 LibreOffice，再运行此配置包。不会强制结束进程。'
}
if (!(Test-Path -LiteralPath $config)) { throw '请先启动并关闭一次 LibreOffice，生成用户配置。' }
[xml]$doc = Get-Content -LiteralPath $config -Raw -Encoding UTF8
$changes = @(
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
    @("/org.openoffice.Office.UI.ToolbarMode/Applications/Writer/Modes/Tabbed",'Sidebar','Opened'),
    @("/org.openoffice.Office.UI.ToolbarMode/Applications/Calc/Modes/Tabbed",'Sidebar','Arrow')
)
# 固定前十二项保持 v1-v3 升级兼容；新增名称设置记录独立恢复键。
$labelSettings = ConvertFrom-Json -InputObject (Get-Content -LiteralPath (Join-Path $PSScriptRoot '设置清单.json') -Raw -Encoding UTF8)
foreach ($setting in $labelSettings) { $changes += ,@($setting.Path,$setting.Name,$setting.Value,$setting.Localized) }
$uiBackup = Join-Path $env:APPDATA 'LibreOffice\wps-ui-files-backup'
$uiState = Join-Path $uiBackup 'state.json'
if (!$Restore) {
    $versionFile = Join-Path $LibreOfficePath 'program\version.ini'
    if (!(Test-Path -LiteralPath $versionFile) -or !(Select-String -LiteralPath $versionFile -Pattern '^buildid=cd7284b4cbbfeb507e630c1aac019f4157393acb$' -Quiet)) {
        throw '本定制功能区只验证用于 LibreOffice 26.2.5.2。其他版本请重新生成匹配文件，未修改设置。'
    }
    foreach ($module in @('swriter','scalc')) {
        [xml]$uiCheck = Get-Content -LiteralPath (Join-Path $PSScriptRoot "ui\$module\notebookbar.ui") -Raw -Encoding UTF8
        if (!$uiCheck.SelectSingleNode('//object[@id="ContextContainer"]')) { throw '功能区文件不完整，未修改设置。' }
    }
}
function Find-Settings($path, $name) {
    @($doc.DocumentElement.ChildNodes | Where-Object {
        $_.GetAttribute('path',$ns) -eq $path -and @($_.ChildNodes | Where-Object { $_.LocalName -eq 'prop' -and $_.GetAttribute('name',$ns) -eq $name }).Count -gt 0
    })
}
if ($Restore) {
    if (!(Test-Path -LiteralPath $backup)) { throw '没有找到此配置包的备份。' }
    [xml]$saved = Get-Content -LiteralPath $backup -Raw -Encoding UTF8
    if ($saved.DocumentElement.GetAttribute('version') -eq '4') {
        $changes = @($saved.SelectNodes('/backup/tracked/setting') | ForEach-Object { ,@($_.path,$_.name) })
    } else { $changes = @($changes | Select-Object -First $(if ($saved.DocumentElement.GetAttribute('version') -in @('2','3')) { 12 } else { 5 })) }
} else {
    if (Test-Path -LiteralPath $backup) {
        [xml]$saved = Get-Content -LiteralPath $backup -Raw -Encoding UTF8
        $count = if ($saved.DocumentElement.GetAttribute('version') -in @('2','3')) { 12 } else { 5 }
        $already = if ($saved.DocumentElement.GetAttribute('version') -eq '4') {
            @($saved.SelectNodes('/backup/tracked/setting') | ForEach-Object { "$($_.path)|$($_.name)" })
        } else { @($changes | Select-Object -First $count | ForEach-Object { "$($_[0])|$($_[1])" }) }
    } else {
        $saved = New-Object System.Xml.XmlDocument
        $saved.LoadXml('<backup/>')
        $already = @()
    }
    $tracked = $saved.SelectSingleNode('/backup/tracked')
    if (!$tracked) { $tracked = $saved.CreateElement('tracked'); $saved.DocumentElement.AppendChild($tracked) | Out-Null }
    foreach ($change in $changes) {
        if ("$($change[0])|$($change[1])" -notin $already) {
            foreach ($item in (Find-Settings $change[0] $change[1])) {
                $copy = $saved.ImportNode($item,$true)
                foreach ($prop in @($copy.ChildNodes)) {
                    if ($prop.GetAttribute('name',$ns) -ne $change[1]) { $copy.RemoveChild($prop) | Out-Null }
                }
                $saved.DocumentElement.AppendChild($copy) | Out-Null
            }
        }
        if (!@($tracked.SelectNodes('setting') | Where-Object { $_.path -eq $change[0] -and $_.name -eq $change[1] }).Count) {
            $setting = $saved.CreateElement('setting')
            $setting.SetAttribute('path',$change[0]); $setting.SetAttribute('name',$change[1])
            $tracked.AppendChild($setting) | Out-Null
        }
    }
    $saved.DocumentElement.SetAttribute('version','4')
    $saved.Save($backup)
}
foreach ($change in $changes) {
    foreach ($item in (Find-Settings $change[0] $change[1])) {
        foreach ($prop in @($item.ChildNodes)) {
            if ($prop.LocalName -eq 'prop' -and $prop.GetAttribute('name',$ns) -eq $change[1]) { $item.RemoveChild($prop) | Out-Null }
        }
        if (!$item.HasChildNodes) { $doc.DocumentElement.RemoveChild($item) | Out-Null }
    }
    if (!$Restore) {
        $item = $doc.CreateElement('item')
        $item.SetAttribute('path',$ns,$change[0]) | Out-Null
        $prop = $doc.CreateElement('prop')
        $prop.SetAttribute('name',$ns,$change[1]) | Out-Null
        $prop.SetAttribute('op',$ns,'fuse') | Out-Null
        $value = $doc.CreateElement('value')
        $value.InnerText = $change[2]
        if ($change.Count -gt 3 -and $change[3]) {
            $lang = $doc.CreateAttribute('xml','lang','http://www.w3.org/XML/1998/namespace')
            $lang.Value = 'zh-CN'; $value.Attributes.Append($lang) | Out-Null
        }
        $prop.AppendChild($value) | Out-Null
        $item.AppendChild($prop) | Out-Null
        $doc.DocumentElement.AppendChild($item) | Out-Null
    }
}
if ($Restore) {
    foreach ($item in $saved.DocumentElement.SelectNodes('item')) {
        # 仅恢复本包修改的属性，保留同一节点下的其他设置。
        $copy = $doc.ImportNode($item,$true)
        foreach ($prop in @($copy.ChildNodes)) {
            if (!@($changes | Where-Object { $_[0] -eq $item.GetAttribute('path',$ns) -and $_[1] -eq $prop.GetAttribute('name',$ns) }).Count) { $copy.RemoveChild($prop) | Out-Null }
        }
        if ($copy.HasChildNodes) { $doc.DocumentElement.AppendChild($copy) | Out-Null }
    }
}
$uiFiles = @()
if (Test-Path -LiteralPath $uiState) {
    $uiFiles = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $uiState -Raw -Encoding UTF8)
    if ($uiFiles.Count -ne 2 -or @($uiFiles.Module | Sort-Object -Unique).Count -ne 2 -or
        @($uiFiles | Where-Object { $_.Module -notin @('swriter','scalc') -or $_.Existed -isnot [bool] }).Count) {
        throw '界面备份清单格式不正确，未修改界面文件。'
    }
    foreach ($entry in $uiFiles) {
        if ($entry.Existed -and !(Test-Path -LiteralPath (Join-Path $uiBackup "$($entry.Module).ui"))) {
            throw '原界面备份文件缺失，未修改界面文件。'
        }
    }
}
if (!$Restore) {
    if (!$uiFiles.Count) {
        New-Item -ItemType Directory -Path $uiBackup -Force | Out-Null
        foreach ($module in @('swriter','scalc')) {
            $target = Join-Path $env:APPDATA "LibreOffice\4\user\config\soffice.cfg\modules\$module\ui\notebookbar.ui"
            $existed = Test-Path -LiteralPath $target
            if ($existed) { Copy-Item -LiteralPath $target -Destination (Join-Path $uiBackup "$module.ui") -Force }
            $uiFiles += [pscustomobject]@{ Module=$module; Existed=$existed }
        }
        $uiFiles | ConvertTo-Json | Set-Content -LiteralPath $uiState -Encoding UTF8
    }
}
$temp = "$config.wps-ui.tmp"
$doc.Save($temp)
[xml]$verified = Get-Content -LiteralPath $temp -Raw -Encoding UTF8
# 两个 UI 文件均写入成功后才提交配置；失败时恢复本次操作前的 UI。
$stage = Join-Path $env:APPDATA ('LibreOffice\wps-ui-stage-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
$current = @{}
foreach ($module in @('swriter','scalc')) {
    $target = Join-Path $env:APPDATA "LibreOffice\4\user\config\soffice.cfg\modules\$module\ui\notebookbar.ui"
    $current[$module] = Test-Path -LiteralPath $target
    if ($current[$module]) { Copy-Item -LiteralPath $target -Destination (Join-Path $stage "$module.ui") }
}
try {
    foreach ($entry in $uiFiles) {
        $target = Join-Path $env:APPDATA "LibreOffice\4\user\config\soffice.cfg\modules\$($entry.Module)\ui\notebookbar.ui"
        if (!$Restore -or $entry.Existed) {
            $source = if ($Restore) { Join-Path $uiBackup "$($entry.Module).ui" } else { Join-Path $PSScriptRoot "ui\$($entry.Module)\notebookbar.ui" }
            New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $target -Force
        }
        elseif (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target }
    }
    Move-Item -LiteralPath $temp -Destination $config -Force
} catch {
    foreach ($module in @('swriter','scalc')) {
        $target = Join-Path $env:APPDATA "LibreOffice\4\user\config\soffice.cfg\modules\$module\ui\notebookbar.ui"
        if ($current[$module]) { Copy-Item -LiteralPath (Join-Path $stage "$module.ui") -Destination $target -Force }
        elseif (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target }
    }
    throw
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp }
    foreach ($module in @('swriter','scalc')) {
        $file = Join-Path $stage "$module.ui"
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
    }
    Remove-Item -LiteralPath $stage
}
if ($Restore) {
    Remove-Item -LiteralPath $backup
    if (Test-Path -LiteralPath $uiState) { Remove-Item -LiteralPath $uiState }
    foreach ($module in @('swriter','scalc')) {
        $file = Join-Path $uiBackup "$module.ui"
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
    }
    Write-Host '已恢复原界面设置、按钮名称与原功能区文件。'
} else { Write-Host '已安装 LibreOfficePlus v4。重新打开 Writer 和 Calc 查看界面。' }
