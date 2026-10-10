"""从固定版本的原生 UI 构建可恢复的 WPS 习惯配置包，仅使用标准库。"""
import copy
import csv
import json
import xml.etree.ElementTree as ET
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "package"
LAYOUT = json.loads((ROOT / "config/layout.json").read_text(encoding="utf-8"))
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
    def __init__(self, module):
        self.module = module
        self.tree = ET.parse(ROOT / "vendor/libreoffice" / module / "notebookbar.ui")
        self.root = self.tree.getroot()
        self.notebook = self.root.find('.//object[@id="ContextContainer"]')
        self.templates = {}
        for obj in self.root.iter("object"):
            if obj.get("class") in BUTTONS and action(obj):
                self.templates.setdefault(action(obj), copy.deepcopy(obj))
        self.counter = 0
        self.records = []

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
        prop(obj, "tooltip-text", label)
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

    def section(self, items, separator=True):
        section = self.make("VclOptionalBox")
        prop(section, "valign", "center")
        prop(section, "vexpand", "True")
        if separator:
            sep = self.make("GtkSeparator")
            prop(sep, "orientation", "vertical")
            prop(sep, "margin-start", "5")
            prop(sep, "margin-end", "5")
            ET.SubElement(section, "child").append(sep)
        ET.SubElement(section, "child").append(self.toolbar(items))
        ET.SubElement(ET.SubElement(section, "style"), "class", {"name": "priority-8"})
        return section

    def move_button(self, ident, target):
        obj = self.obj(ident)
        parent = next(n for n in self.root.iter() if obj in list(n))
        oldbar = next(n for n in self.root.iter() if parent in list(n))
        oldbar.remove(parent)
        target.append(parent)

    def home(self):
        home = self.obj("Home")
        sections = {c.find("object").get("id"): c for c in home.findall("child")}
        # 格式刷独立大按钮，剪切/复制保留原生命令，清除格式放在字号旁。
        brush = self.obj("Home-Section-Style")
        reset = self.obj("Home-ResetAttributes")
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
        order = ["Style", "Clipboard", "Format"]
        removed = []
        if self.module == "scalc":
            order += ["Align", "Cell", "Number", "Cell1", "Condition", "Style2"]
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
            tools = [{"label": label, "command": ".uno:" + cmd} for label, cmd in
                     [("填充", "FillDown"), ("求和", "AutoSum"), ("排序", "DataSort"),
                      ("筛选", "DataFilterAutoFilter"), ("冻结窗格", "FreezePanes"), ("查找", "SearchDialog")]]
            extra = ET.SubElement(home, "child")
            extra.append(self.section(tools))
            order.append("Quick")
            sections["Home-Section-Quick"] = extra
            removed += ["Find", "Find1"]
        else:
            order += ["Paragraph", "Paragraph1", "Style3"]
            prop(self.obj("Home-Shadowed"), "visible", "False")
            removed += ["Insert", "View"]
            extra = ET.SubElement(home, "child")
            extra.append(self.section([{"label": label, "command": ".uno:" + cmd} for label, cmd in
                                      [("样式窗格", "SidebarDeck.StyleListDeck"), ("查找替换", "SearchDialog"),
                                       ("批注", "InsertAnnotation"), ("选择全部", "SelectAll")]]))
            sections["Home-Section-Quick"] = extra
            order.append("Quick")
        first = [sections["Home-Section-" + name] for name in order]
        for name in removed:
            home.remove(sections["Home-Section-" + name])
        reorder(home, first + [c for c in home.findall("child") if c not in first])
        self.records.extend([[self.module, "开始", action(o), o.get("id"), "保留原生控件或增加常用入口"]
                             for o in home.iter("object") if action(o)])

    def tabs(self):
        if self.module == "scalc":
            extension = self.notebook.find('./child/object[@id="Extension Tab"]/..')
            extension.remove(extension.find("object"))
            formula = copy.deepcopy(self.obj("Tools Tab"))
            for obj in formula.iter("object"):
                self.counter += 1
                obj.set("id", f"WPS-{self.module}-{self.counter}")
            formula.set("id", "Formula Tab")
            extension.insert(0, formula)
            self.obj("ExtensionLabel").set("id", "FormulaLabel")
        for tab, groups in LAYOUT["modules"][self.module].items():
            page = self.obj(tab + " Tab")
            items = [item for group in groups for item in group]
            available = [i for i in items if i["command"] in KNOWN or i["command"] in self.templates]
            slots = [n for n in page.iter("object") if n.get("class") in BUTTONS]
            assert len(slots) >= len(available)
            for index, obj in enumerate(slots):
                if index < len(available):
                    item = available[index]
                    template = self.templates.get(item["command"])
                    obj.set("class", template.get("class") if template is not None else "GtkToolButton")
                    for p in list(obj.findall("property")):
                        if p.get("name").replace("_", "-") in {"icon-name", "width-request"}:
                            obj.remove(p)
                    prop(obj, "visible", "True")
                    prop(obj, "action-name", item["command"])
                    prop(obj, "label", item["label"])
                    prop(obj, "tooltip-text", item["label"])
                else:
                    prop(obj, "visible", "False")
            for item in items:
                status = "已安排；待具体文档验证" if item in available else "无已确认对应命令，省略"
                self.records.append([self.module, LAYOUT["tabs"][tab], item["command"], item["label"], status])
        children = self.notebook.findall("child")
        pairs = list(zip(children[::2], children[1::2]))
        order = ["File", "Home", "Insert", "Layout"] + (["References"] if self.module == "swriter" else ["Formula", "Data"]) + ["Review", "View", "Tools"]
        pairs.sort(key=lambda pair: order.index(pair[0].find("object").get("id").removesuffix(" Tab"))
                   if pair[0].find("object").get("id").removesuffix(" Tab") in order else 99)
        for page, label in pairs:
            name = page.find("object").get("id").removesuffix(" Tab")
            if name in LAYOUT["tabs"]:
                prop(label.find("object"), "label", LAYOUT["tabs"][name])
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
        target = PACKAGE / "ui" / self.module / "notebookbar.ui"
        target.parent.mkdir(parents=True, exist_ok=True)
        ET.indent(self.tree, space="  ")
        self.tree.write(target, encoding="utf-8", xml_declaration=True)


def main():
    records = []
    for module in LAYOUT["modules"]:
        builder = Builder(module)
        builder.home()
        builder.tabs()
        builder.write()
        records.extend(builder.records)
    with (PACKAGE / "按钮对应表.csv").open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["模块", "选项卡", "LibreOffice命令", "按钮文字或控件ID", "状态"])
        writer.writerows(records)
    (PACKAGE / "设置清单.json").write_text((ROOT / "config/labels.json").read_text(encoding="utf-8"), encoding="utf-8")
    for source, dest in [("README.md", "使用说明.txt"), ("LICENSE", "LICENSE.txt"),
                         ("NOTICE", "来源说明.txt"), ("docs/验收记录.md", "验证记录.txt")]:
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
