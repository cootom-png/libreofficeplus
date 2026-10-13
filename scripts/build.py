"""从固定版本的原生 UI 构建可恢复的 WPS 习惯配置包，仅使用标准库。"""
import copy
import csv
import sys
import json
import xml.etree.ElementTree as ET
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo
from templates import build_templates
from popups import build_popups

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "package"
LAYOUT = json.loads((ROOT / "config/layout.json").read_text(encoding="utf-8"))
HOME = json.loads((ROOT / "config/home.json").read_text(encoding="utf-8"))
KNOWN = set(json.loads((ROOT / "config/commands.json").read_text(encoding="utf-8")))
BUTTONS = {"GtkToolButton", "GtkMenuToolButton", "GtkToggleToolButton"}


def prop(obj, name, value):
    for old in list(obj.findall("property")):
        if old.get("name").replace("_", "-") == name.replace("_", "-"):
            obj.remove(old)
    entry = ET.Element("property", {"name": name})
    entry.text = str(value)
    obj.insert(0, entry)


def action(obj):
    return next((p.text for p in obj.findall("property")
                 if p.get("name").replace("_", "-") == "action-name"), "")


def reorder(obj, children):
    for child in obj.findall("child"):
        obj.remove(child)
    for index, child in enumerate(children):
        packing = child.find("packing")
        if packing is None:
            packing = ET.SubElement(child, "packing")
            prop(packing, "expand", "False")
            prop(packing, "fill", "True")
        prop(packing, "position", index)
        obj.append(child)


class Builder:
    def __init__(self, module, source=None, package=PACKAGE):
        self.module = module
        self.source = source or ROOT / "vendor/libreoffice"
        self.package = package
        self.tree = ET.parse(self.source / module / "notebookbar.ui")
        self.root = self.tree.getroot()
        self.notebook = self.root.find('.//object[@id="ContextContainer"]')
        self.templates = {}
        for obj in self.root.iter("object"):
            if obj.get("class") in BUTTONS and action(obj):
                self.templates.setdefault(action(obj), copy.deepcopy(obj))
        self.counter = 0
        self.records = []
        self.modern = self.root.find('.//object[@id="gdHomeFont"]') is not None
        if self.modern:
            for obj in self.root.iter('object'):
                if not obj.get('id'):
                    self.counter += 1
                    obj.set('id', f'Native-{self.module}-{self.counter}')
            # 26.8 的网格功能区有独立公式页；统一页名，保留全部实际上下文页。
            children = self.notebook.findall('child')
            for page, label in zip(children[::2], children[1::2]):
                if page.find('object') is None:
                    self.notebook.remove(page)
                    self.notebook.remove(label)
                    continue
                name = label.find('object').get('id').removesuffix('Label')
                name = {'FunctionsLabel1': 'Formula', 'Dev': 'Tools', 'SlideShow': 'Slide Show',
                        'Design': 'Theme', '3DObject': '3D'}.get(name, name)
                if self.module == 'sdraw' and name == 'Layout':
                    name = 'Page'
                page.find('object').set('id', name + ' Tab')
                label.find('object').set('id', name + 'Label')
                if name == 'Theme':
                    prop(label.find('object'), 'label', '主题')
            body = next(o for o in self.obj('Home Tab').iter('object') if o.get('class') == 'sfxlo-PriorityMergedHBox')
            body.set('id', 'Home')

    def obj(self, ident):
        found = self.root.find(f'.//object[@id="{ident}"]')
        if found is None:
            raise ValueError(f"缺少原生控件：{self.module}/{ident}")
        return found

    def make(self, cls):
        self.counter += 1
        obj = ET.Element("object", {"class": cls, "id": f"WPS-{self.module}-{self.counter}"})
        prop(obj, "visible", "True")
        return obj

    def button(self, item):
        cmd, label = item["command"], item["label"]
        obj = copy.deepcopy(self.templates.get(cmd))
        if obj is None:
            obj = self.make("GtkToolButton")
        else:
            for node in obj.iter("object"):
                self.counter += 1
                node.set("id", f"WPS-{self.module}-{self.counter}")
        prop(obj, "visible", "True")
        prop(obj, "action-name", cmd)
        prop(obj, "label", label)
        prop(obj, "tooltip-text", item.get("tooltip", label))
        return obj

    def toolbar(self, items, large=True):
        bar = self.make("sfxlo-NotebookbarToolBox")
        for key, value in {"can-focus": "True", "valign": "center", "vexpand": "True",
                           "toolbar-style": "both" if large else "both-horiz",
                           "show-arrow": "False", "icon-size": "3" if large else "1"}.items():
            prop(bar, key, value)
        for item in items:
            ET.SubElement(bar, "child").append(self.button(item))
        return bar

    def menu_button(self, item):
        menu = self.make("GtkMenu")
        self.root.insert(0, menu)
        for entry in item["menu"]:
            command = self.make("GtkSeparatorMenuItem" if entry.get("separator") else "GtkMenuItem")
            if not entry.get("separator"):
                prop(command, "label", entry["label"])
                prop(command, "action-name", entry["command"])
            ET.SubElement(menu, "child").append(command)
        button = self.make("svtlo-ManagedMenuButton")
        button.set("id", button.get("id") + ":" + menu.get("id"))
        for name, value in {"label": item["label"], "relief": "none", "valign": "center",
                            "can-focus": "True", "focus-on-click": "False"}.items():
            prop(button, name, value)
        return button

    def quick_section(self, rows):
        section = self.make("VclOptionalBox")
        prop(section, "valign", "center")
        prop(section, "margin-start", "5")
        prop(section, "margin-end", "5")
        stack = self.make("GtkBox")
        prop(stack, "orientation", "vertical")
        prop(stack, "spacing", "4")
        ET.SubElement(section, "child").append(stack)
        for items in rows:
            row = self.make("GtkBox")
            ET.SubElement(stack, "child").append(row)
            for item in items:
                widget = self.menu_button(item) if "menu" in item else self.toolbar([item], large=False)
                ET.SubElement(row, "child").append(widget)
        ET.SubElement(ET.SubElement(section, "style"), "class", {"name": "priority-8"})
        return section

    def move_button(self, ident, target):
        obj = self.obj(ident)
        parent = next(n for n in self.root.iter() if obj in list(n))
        oldbar = next(n for n in self.root.iter() if parent in list(n))
        oldbar.remove(parent)
        target.append(parent)

    def home(self):
        if self.modern:
            self.modern_home()
            return
        home = self.obj("Home")
        if self.module == "sdraw":
            source = ET.parse(self.source / "swriter/notebookbar.ui")
            font = copy.deepcopy(source.find('.//object[@id="Home-Section-Format"]'))
            for obj in font.iter("object"):
                if obj is not font:
                    obj.set("id", "DrawFont-" + obj.get("id"))
            ET.SubElement(home, "child").append(font)
        sections = {c.find("object").get("id"): c for c in home.findall("child")}
        # 格式刷独立大按钮，剪切/复制保留原生命令，清除格式放在字号旁。
        brush = self.obj("Home-Section-Style")
        reset = self.obj("Home-SetDefault" if self.module in {"sdraw", "simpress"} else "Home-ResetAttributes")
        fontbar = next(n for n in self.obj("Home-Section-Format").iter("object")
                       if any(action(o) == ".uno:Shrink" for o in n.findall("child/object")))
        self.move_button(reset.get("id"), fontbar)
        for c in brush.findall("child"):
            brush.remove(c)
        ET.SubElement(brush, "child").append(self.toolbar([
            {"label": "格式刷", "command": ".uno:FormatPaintbrush"}]))
        for ident in ("Home-Cut", "Home-Copy"):
            obj = self.obj(ident)
            bar = next(n for n in self.root.iter("object") if obj in n.findall("child/object"))
            prop(bar, "toolbar-style", "icons")
        removed = []
        if self.module == "scalc":
            # WPS 的换行与合并紧跟在对齐按钮后面。
            cellbar = self.obj("Home-Section-Cell").find('.//object[@class="sfxlo-NotebookbarToolBox"]')
            self.move_button("Home-WrapText", cellbar)
            reorder(cellbar, list(reversed(cellbar.findall("child"))))
            align = self.obj("Home-Section-Align")
            top = next(n for n in align.iter("object") if any(action(o) == ".uno:AlignTop" for o in n.findall("child/object")))
            for ident in ["Home-DecrementIndent", "Home-IncrementIndent"]:
                self.move_button(ident, top)
            removed.append("Align1")
            # 精简原生单元格样式预览，保留下拉框和格式设置入口。
            styles = self.obj("Home-Section-Style2")
            for obj in styles.iter("object"):
                if action(obj).startswith(".uno:StyleApply?"):
                    prop(obj, "visible", "False")
            bars = [n for n in styles.iter("object") if n.get("class") == "sfxlo-NotebookbarToolBox"]
            ET.SubElement(bars[-1], "child").append(self.button({"label": "单元格格式", "command": ".uno:FormatCellDialog"}))
            removed += ["Find", "Find1"]
        elif self.module == "swriter":
            prop(self.obj("Home-Shadowed"), "visible", "False")
            removed += ["Insert", "View"]
            # 将缩进、行距与段落标记放回段落区的上下两行。
            top = self.obj("SectionBottom91")
            bottom = self.obj("SectionBottom13")
            for ident in ["Home-DecrementIndent1", "Home-IncrementIndent1", "Home-ControlCodes1"]:
                self.move_button(ident, top)
            self.move_button("Home-LineSpacing1", bottom)
            removed.append("Paragraph1")
        elif self.module == "simpress":
            # 保留演示原生字体、段落与形状控制器；幻灯片操作紧跟剪贴板。
            slides = self.make("VclOptionalBox")
            slides.set("id", "Home-Section-Slides")
            ET.SubElement(slides, "child").append(self.toolbar([
                {"label": label, "command": ".uno:" + command}
                for label, command in [("新建幻灯片", "InsertSlide"), ("版式", "AssignLayout"),
                                       ("复制幻灯片", "DuplicateSlide"), ("删除幻灯片", "DeleteSlide")]]))
            sections[slides.get("id")] = ET.SubElement(home, "child")
            sections[slides.get("id")].append(slides)
            removed.append("Slideshow")
        else:
            removed += ["DrawColor", "Arrange1", "Arrange2"]
        spec = HOME[self.module]
        for bar_id, buttons in spec.get("toolbar_rows", {}).items():
            bar = self.obj(bar_id)
            children = bar.findall("child")
            selected = [next(c for c in children if c.find("object").get("id") == ident) for ident in buttons]
            reorder(bar, selected + [c for c in children if c not in selected])
        extra = ET.SubElement(home, "child")
        extra.append(self.quick_section(spec["quick_rows"]))
        sections["Home-Section-Quick"] = extra
        order = spec["sections"]
        first = [sections["Home-Section-" + name] for name in order]
        for name in removed:
            home.remove(sections["Home-Section-" + name])
        reorder(home, first + [c for c in home.findall("child") if c not in first])
        for child in home.findall('child'):
            section = child.find('object')
            for index, obj in enumerate(o for o in section.iter('object') if action(o)):
                self.records.append([self.module, '开始', action(obj), obj.get('id'),
                                     section.get('id'), index + 1, '保留原生控件或增加常用入口'])
        for row, items in enumerate(spec['quick_rows'], 1):
            for item in items:
                for entry in item.get('menu', []):
                    if entry.get('separator'):
                        continue
                    self.records.append([self.module, '开始', entry['command'], entry['label'],
                                         '常用操作/' + item['label'], row, '菜单入口；行号指上级按钮所在行'])

    def modern_home(self):
        home = self.obj('Home')
        # 保留新版原生字体、段落、数字、版式和样式控制器及网格定位。
        for obj in home.iter('object'):
            if action(obj) == '.uno:FormatPaintbrush':
                prop(obj, 'visible', 'False')
        brush = self.make('VclOptionalBox')
        brush.set('id', 'Home-Section-Style')
        ET.SubElement(brush, 'child').append(self.toolbar([{'label': '格式刷', 'command': '.uno:FormatPaintbrush'}]))
        first = ET.SubElement(home, 'child')
        first.append(brush)
        quick = ET.SubElement(home, 'child')
        quick.append(self.quick_section(HOME[self.module]['quick_rows']))
        reorder(home, [first] + [c for c in home.findall('child') if c not in [first, quick]] + [quick])
        for key, text in {'Clipboard':'剪贴板', 'Font':'字体', 'Paragraph':'段落', 'Style':'样式',
                          'Alignment':'对齐', 'Number':'数字', 'Cells':'单元格', 'Slide':'幻灯片', 'Page':'页面'}.items():
            label = home.find('.//object[@id="lbHome' + key + '"]')
            if label is not None:
                prop(label, 'label', text)
        for child in home.findall('child'):
            section = child.find('object')
            for index, obj in enumerate(o for o in section.iter('object') if action(o)):
                self.records.append([self.module, '开始', action(obj), obj.get('id'), section.get('id'), index + 1, '保留新版原生控件或增加常用入口'])

    def tabs(self):
        if self.module == "simpress":
            # 新页复用原生页面容器，保留源页；上下文页与扩展页不占用。
            for name in ["Transition", "Animation"]:
                page = copy.deepcopy(self.notebook.find('./child/object[@id="Layout Tab"]/..'))
                label = copy.deepcopy(self.notebook.find('./child/object[@id="LayoutLabel"]/..'))
                for child in [page, label]:
                    for obj in child.iter("object"):
                        self.counter += 1
                        suffix = ':' + obj.get('id').split(':', 1)[1] if ':' in obj.get('id') else ''
                        obj.set('id', f'Impress-{name}-{self.counter}' + suffix)
                page.find('object').set('id', name + ' Tab')
                label.find('object').set('id', name + 'Label')
                # 克隆页仅显示本页配置入口，避免保留源页菜单与尺寸控制器。
                body = next(o for o in page.iter('object') if o.get('class') == 'sfxlo-PriorityMergedHBox')
                for child in body.findall('child/object'):
                    prop(child, 'visible', 'False')
                for obj in page.iter('object'):
                    if obj.get('class') == 'svtlo-ManagedMenuButton':
                        prop(obj, 'visible', 'False')
                self.notebook.extend([page, label])
        if self.module == "scalc" and not self.modern:
            extension = self.notebook.find('./child/object[@id="Extension Tab"]/..')
            extension.remove(extension.find("object"))
            formula = copy.deepcopy(self.obj("Tools Tab"))
            for obj in formula.iter("object"):
                self.counter += 1
                suffix = ':' + obj.get('id').split(':', 1)[1] if ':' in obj.get('id') else ''
                obj.set("id", f"WPS-{self.module}-{self.counter}" + suffix)
            formula.set("id", "Formula Tab")
            extension.insert(0, formula)
            self.obj("ExtensionLabel").set("id", "FormulaLabel")
        for tab, groups in LAYOUT["modules"][self.module].items():
            page = self.obj(tab + " Tab")
            body = next(n for n in page.iter("object") if n.get("class") == "sfxlo-PriorityMergedHBox")
            if self.modern:
                # 配置页使用本版本原生命令控件，原生菜单和上下文页仍保留。
                for child in body.findall('child'):
                    body.remove(child)
                for index, group in enumerate(groups, 1):
                    container = self.make('VclOptionalBox')
                    ET.SubElement(container, 'child').append(self.toolbar(group))
                    ET.SubElement(body, 'child').append(container)
                    for position, item in enumerate(group, 1):
                        self.records.append([self.module, LAYOUT['tabs'][tab], item['command'], item['label'], f'第 {index} 组', position, '已安排；待具体文档验证'])
                continue
            containers = [o for o in body.findall('child/object') if any(n.get('class') in BUTTONS for n in o.iter('object'))]
            if len(containers) < len(groups):
                raise ValueError(f'{self.module}/{tab} 原生分组数量不足')
            for index, container in enumerate(containers):
                group = groups[index] if index < len(groups) else []
                available = [i for i in group if i["command"] in KNOWN or i["command"] in self.templates]
                if available and self.module == "simpress" and tab in {"Transition", "Animation"}:
                    prop(container, 'visible', 'True')
                slots=[o for o in container.iter('object') if o.get('class') in BUTTONS]
                bars=[o for o in container.iter('object') if o.get('class')=='sfxlo-NotebookbarToolBox']
                while len(slots) < len(available):
                    button=self.button(available[len(slots)])
                    ET.SubElement(bars[-1], 'child').append(button)
                    slots.append(button)
                for slot_index,obj in enumerate(slots):
                    if slot_index < len(available):
                        item=available[slot_index]
                        template=self.templates.get(item['command'])
                        obj.set('class',template.get('class') if template is not None else 'GtkToolButton')
                        for p in list(obj.findall('property')):
                            if p.get('name').replace('_','-') in {'icon-name','width-request'}:
                                obj.remove(p)
                        prop(obj,'visible','True')
                        prop(obj,'action-name',item['command'])
                        prop(obj,'label',item['label'])
                        prop(obj,'tooltip-text',item.get('tooltip',item['label']))
                    else:
                        prop(obj,'visible','False')
                # 仅收起已清空的按钮容器，其他原生控制器继续保留。
                static = ('Box', 'Grid', 'Label', 'Separator', 'SeparatorToolItem', 'Image')
                if not available and all(o.get('class') in BUTTONS or o.get('class', '').endswith(static) for o in container.iter('object')):
                    prop(container, 'visible', 'False')
                for item_index, item in enumerate(group, 1):
                    status = "已安排；待具体文档验证" if item in available else "无已确认对应命令，省略"
                    self.records.append([self.module, "设计" if self.module == "simpress" and tab == "Layout" else LAYOUT["tabs"][tab], item["command"], item["label"],
                                         f'第 {index + 1} 组/{container.get("id")}', item_index, status])
        children = self.notebook.findall("child")
        pairs = list(zip(children[::2], children[1::2]))
        order = ["File", "Home", "Insert", "Page" if self.module == "sdraw" else "Layout"] + (
            ["References"] if self.module == "swriter" else ["Formula", "Data"] if self.module == "scalc" else []) + ["Review", "View", "Tools"]
        if self.module == "simpress":
            order = ["File", "Home", "Insert", "Layout", "Transition", "Animation", "Slide Show", "Review", "View", "Tools"]
        pairs.sort(key=lambda pair: order.index(pair[0].find("object").get("id").removesuffix(" Tab"))
                   if pair[0].find("object").get("id").removesuffix(" Tab") in order else 99)
        for page, label in pairs:
            name = page.find("object").get("id").removesuffix(" Tab")
            if name in LAYOUT["tabs"]:
                prop(label.find("object"), "label", "设计" if self.module == "simpress" and name == "Layout" else LAYOUT["tabs"][name])
        if self.module == "scalc":
            for obj in self.obj("Formula Tab").iter("object"):
                if obj.get("class") == "svtlo-ManagedMenuButton":
                    prop(obj, "label", "公式工具")
        for child in children:
            self.notebook.remove(child)
        for index, pair in enumerate(pairs):
            for child in pair:
                packing = child.find("packing")
                if packing is None:
                    packing = ET.SubElement(child, "packing")
                prop(packing, "position", index)
                self.notebook.append(child)

    def write(self):
        ids = [n.get("id") for n in self.root.iter("object")]
        assert len(ids) == len(set(ids)), "控件 ID 重复"
        for widgets in self.root.iter("widgets"):
            for widget in list(widgets):
                if widget.get("name") not in ids:
                    widgets.remove(widget)
        target = self.package / "ui" / self.module / "notebookbar.ui"
        target.parent.mkdir(parents=True, exist_ok=True)
        ET.indent(self.tree, space="  ")
        self.tree.write(target, encoding="utf-8", xml_declaration=True)


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    # cmd.exe 的启动入口固定使用 ASCII + CRLF，避免换行/代码页截断命令。
    for name, options in [("安装.cmd", ""), ("恢复原界面.cmd", "-Restore ")]:
        lines = ["@echo off", "setlocal", 'pushd "%~dp0" || exit /b 1',
                 '"%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" '
                 '-NoProfile -ExecutionPolicy Bypass -File ".\\configure.ps1" ' + options + '%*',
                 'set "result=%errorlevel%"', "popd", "pause", "exit /b %result%"]
        (PACKAGE / name).write_bytes(("\r\n".join(lines) + "\r\n").encode("ascii"))
    # WScript 在创建 PowerShell 时即隐藏控制台；作为默认双击入口。
    for name, options in [("安装.vbs", ""), ("恢复原界面.vbs", " -Restore"), ("兼容升级.vbs", " -Upgrade")]:
        lines = ['Option Explicit', 'Dim shell, files, scriptPath, command',
                 'Set shell = CreateObject("WScript.Shell")',
                 'Set files = CreateObject("Scripting.FileSystemObject")',
                 'scriptPath = files.BuildPath(files.GetParentFolderName(WScript.ScriptFullName), "installer-ui.ps1")',
                 'command = Chr(34) & shell.ExpandEnvironmentStrings("%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe") & Chr(34) & '
                 '" -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & scriptPath & Chr(34) & "' + options + '"',
                 'On Error Resume Next', 'shell.Run command, 0, False',
                 'If Err.Number <> 0 Then',
                 '  shell.Popup "Unable to start LibreOfficePlus: " & Err.Description, 0, "LibreOfficePlus", 16',
                 '  WScript.Quit 1', 'End If']
        (PACKAGE / name).write_bytes(("\r\n".join(lines) + "\r\n").encode("ascii"))
    build_templates(PACKAGE)
    compatibility, shared_builds, records = [], [], []
    for entry in json.loads((ROOT / 'config/versions.json').read_text('utf8')):
        source, package = ROOT / entry['Source'], PACKAGE / entry['Bundle']
        metadata = json.loads((source / 'SOURCE.json').read_text('utf8'))
        compatibility.append({'Version': metadata['version'], 'DisplayVersion': metadata.get('display_version', metadata['version']),
                              'BuildId': metadata['buildid'], 'Bundle': entry['Bundle']})
        for compatible in metadata.get('compatible_builds', []):
            if {key: value['sha256'] for key, value in compatible['files'].items()} != {key: value['sha256'] for key, value in metadata['files'].items()}:
                raise ValueError('共用界面的构建必须具有完全一致的原生来源')
            shared_builds.append({'Version': compatible['version'], 'DisplayVersion': compatible['version'],
                                  'BuildId': compatible['buildid'], 'Bundle': entry['Bundle']})
        package.mkdir(parents=True, exist_ok=True)
        profile_files = build_popups(ROOT, package, source)
        (package / "profile-files.json").write_text(json.dumps(profile_files, indent=2) + '\n', encoding="utf-8", newline='\n')
        profile_records = []
        for module in LAYOUT["modules"]:
            builder = Builder(module, source, package)
            builder.home()
            builder.tabs()
            builder.write()
            profile_records.extend(builder.records)
            if entry['Bundle'] == '.':
                records.extend(builder.records)
        if entry['Bundle'] != '.':
            with (package / '按钮对应表.csv').open('w', encoding='utf-8-sig', newline='') as file:
                writer = csv.writer(file, lineterminator='\n')
                writer.writerow(['模块', '选项卡', 'LibreOffice命令', '配置文字或控件ID', '逻辑分组', '组内顺序或菜单所在行', '状态'])
                writer.writerows(profile_records)
    compatibility.extend(shared_builds)
    (PACKAGE / 'compatibility.json').write_text(json.dumps(compatibility, ensure_ascii=False, indent=2) + '\n', 'utf8', newline='\n')
    with (PACKAGE / "按钮对应表.csv").open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.writer(f, lineterminator='\n')
        writer.writerow(["模块", "选项卡", "LibreOffice命令", "配置文字或控件ID", "逻辑分组", "组内顺序或菜单所在行", "状态"])
        writer.writerows(records)
    settings = []
    for name in ['labels', 'shortcuts', 'appearance', 'updates']:
        settings.extend(json.loads((ROOT / f'config/{name}.json').read_text(encoding='utf-8')))
    (PACKAGE / "设置清单.json").write_text(json.dumps(settings, ensure_ascii=False, indent=2) + '\n', encoding="utf-8", newline='\n')
    modules = {'com.sun.star.text.TextDocument': 'Writer 文字', 'com.sun.star.sheet.SpreadsheetDocument': 'Calc 表格',
               'com.sun.star.drawing.DrawingDocument': 'Draw 绘图', 'com.sun.star.presentation.PresentationDocument': 'Impress 演示'}
    with (PACKAGE / '快捷键对照表.csv').open('w', encoding='utf-8-sig', newline='') as file:
        writer = csv.writer(file, lineterminator='\n')
        writer.writerow(['模块', '快捷键', '动作', 'LibreOffice命令'])
        for entry in json.loads((ROOT / 'config/shortcuts.json').read_text('utf8')):
            writer.writerow([modules[entry['Path'].split('/')[-2]], entry['Shortcut'], entry['Label'], entry['Value']])
    for source, dest in [("README.md", "使用说明.txt"), ("LICENSE", "LICENSE.txt"),
                         ("NOTICE", "来源说明.txt"), ("docs/验收记录.md", "验证记录.txt"),
                         ("docs/操作习惯.md", "操作习惯.txt"), ("docs/按钮差异.md", "按钮差异.txt"),
                         ("docs/布局排查.md", "布局排查.txt"),
                         ("docs/界面间距说明.md", "界面间距说明.txt"),
                         ("docs/适配计划.md", "适配计划.txt"),
                         ("docs/演示适配.md", "演示适配.txt"),
                         ("docs/版本兼容.md", "版本兼容.txt"),
                         ("docs/兼容升级.md", "兼容升级.txt"),
                         ("docs/弹窗菜单设计.md", "弹窗菜单设计.txt")]:
        if (ROOT / source).exists():
            (PACKAGE / dest).write_bytes((ROOT / source).read_bytes())
    out = ROOT / "dist"
    out.mkdir(exist_ok=True)
    with ZipFile(out / "LibreOfficePlus-WPS界面配置包.zip", "w", ZIP_DEFLATED) as archive:
        for file in sorted(PACKAGE.rglob("*")):
            if file.is_file():
                entry = ZipInfo("LibreOfficePlus/" + file.relative_to(PACKAGE).as_posix(), (2026, 10, 10, 0, 0, 0))
                entry.compress_type = ZIP_DEFLATED
                entry.external_attr = 0o644 << 16
                archive.writestr(entry, file.read_bytes())
    print(f"已生成配置包；{len(records)} 条入口记录（含原生控件和省略项）。")


if __name__ == "__main__":
    main()
