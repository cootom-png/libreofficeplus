"""使用固定原生菜单重排常用组，保留未匹配命令与动态子菜单。"""
import json
import xml.etree.ElementTree as ET

NS = "http://openoffice.org/2001/menu"
ID = "{" + NS + "}id"
SEP = "{" + NS + "}menuseparator"
ET.register_namespace("menu", NS)


def clean(menu):
    previous_separator = True
    for child in list(menu):
        if child.tag == SEP and previous_separator:
            menu.remove(child)
        else:
            previous_separator = child.tag == SEP
        for nested in child.findall("{" + NS + "}menupopup"):
            clean(nested)
    if len(menu) and menu[-1].tag == SEP:
        menu.remove(menu[-1])


def build_popups(root, package):
    specs = json.loads((root / "config/popups.json").read_text("utf8"))
    labels = json.loads((root / "config/popup-labels.json").read_text("utf8"))
    files = []
    for key, spec in specs.items():
        module, name = key.split("/")
        source = root / "vendor/libreoffice" / module / "popupmenu" / (name + ".xml")
        tree = ET.parse(source)
        menu = tree.getroot()
        for command in spec["lift"]:
            node = menu.find('.//*[@' + ID + '=".uno:' + command + '"]')
            if node is None:
                raise ValueError(f"缺少弹窗入口：{key}/{command}")
            parent = next(p for p in menu.iter() if node in list(p))
            parent.remove(node)
            menu.append(node)
        nodes = {c.get(ID): c for c in menu if c.get(ID)}
        ordered = []
        for group in spec["groups"]:
            selected = [nodes.pop(".uno:" + cmd) for cmd in group if ".uno:" + cmd in nodes]
            if selected:
                ordered.extend(selected)
                ordered.append(ET.Element(SEP))
        # 未列出的高级和上下文动作保留原顺序，不丢失动态控制器或隐藏条件。
        ordered.extend(c for c in menu if c.tag == SEP or c in nodes.values())
        menu[:] = ordered
        clean(menu)
        for node in menu.iter():
            command = node.get(ID, '').removeprefix('.uno:')
            if command in labels:
                node.set('{' + NS + '}label', labels[command])
        path = f"config/soffice.cfg/modules/{module}/popupmenu/{name}.xml"
        target = package / "profile" / path
        target.parent.mkdir(parents=True, exist_ok=True)
        ET.indent(tree, space="  ")
        with target.open('wb') as file:
            tree.write(file, encoding="utf-8", xml_declaration=True)
        files.append({"Module": module, "Path": path})
    return files
