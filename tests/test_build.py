"""检查配置包中的 UI 结构、引用完整性和可重复构建。"""
import hashlib
import json
import subprocess
import sys
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]


class PackageTests(unittest.TestCase):
    def test_baseline_hashes(self):
        source = json.loads((ROOT / 'vendor/libreoffice/SOURCE.json').read_text(encoding='utf-8'))
        for item in source['files'].values():
            self.assertEqual(hashlib.sha256((ROOT / 'vendor/libreoffice' / item['path']).read_bytes()).hexdigest(), item['sha256'])

    def test_ui_structure(self):
        for module in ["swriter", "scalc", "sdraw"]:
            root = ET.parse(ROOT / "package/ui" / module / "notebookbar.ui").getroot()
            ids = [n.get("id") for n in root.iter("object")]
            self.assertEqual(len(ids), len(set(ids)), module)
            for widget in root.findall(".//widgets/widget"):
                self.assertIn(widget.get("name"), ids)
            notebook = root.find('.//object[@id="ContextContainer"]')
            self.assertIsNotNone(notebook)
            children = notebook.findall("child")
            for i in range(0, len(children), 2):
                page, label = children[i:i + 2]
                self.assertEqual(label.get("type"), "tab")
                self.assertEqual(page.find('packing/property[@name="position"]').text, str(i // 2))
                self.assertEqual(label.find('packing/property[@name="position"]').text, str(i // 2))
            home = root.find('.//object[@id="Home"]')
            self.assertEqual(home.find('child/object').get('id'), 'Home-Section-Style')
            self.assertIsNotNone(home.find('.//property[.=".uno:CharFontName"]'))
            self.assertIsNotNone(home.find('.//property[.=".uno:FontHeight"]'))
            # 图片、表格等上下文功能区继续存在。
            self.assertGreater(len(children), 20)

    def test_grouped_layout_and_menus(self):
        layout=json.loads((ROOT/'config/layout.json').read_text('utf8'))
        known=set(json.loads((ROOT/'config/commands.json').read_text('utf8')))
        for module,tabs in layout['modules'].items():
            root=ET.parse(ROOT/'package/ui'/module/'notebookbar.ui').getroot()
            for tab,groups in tabs.items():
                page=root.find(f'.//object[@id="{tab} Tab"]')
                body=next(n for n in page.iter('object') if n.get('class')=='sfxlo-PriorityMergedHBox')
                # 分组保留独立容器，不再把全部按钮塞入一串原生位置。
                self.assertGreater(len(body.findall('child')),0)
                containers=[o for o in body.findall('child/object') if any(n.get('class') in {'GtkToolButton','GtkMenuToolButton','GtkToggleToolButton'} for n in o.iter('object'))]
                self.assertGreaterEqual(len(containers),len(groups))
                for container,group in zip(containers,groups):
                    actual=[p.text for o in container.iter('object') for p in o.findall('property') if p.get('name').replace('_','-')=='action-name']
                    for item in group:
                        if item['command'] in known:
                            self.assertIn(item['command'],actual)
            for obj in root.iter('object'):
                if obj.get('class')=='svtlo-ManagedMenuButton' and ':' in obj.get('id'):
                    menu=obj.get('id').split(':',1)[1]
                    if menu.startswith('WPS-'):
                        self.assertIsNotNone(root.find(f'./object[@id="{menu}"]'),menu)
        root=ET.parse(ROOT/'package/ui/scalc/notebookbar.ui').getroot()
        for command in ['FillDown','FillRight','FillUp','FillLeft','FillSeries','FreezePanesRow','FreezePanesColumn']:
            self.assertTrue(any(p.text=='.uno:'+command for p in root.iter('property')))

    def test_labels(self):
        labels = json.loads((ROOT / 'package/设置清单.json').read_text(encoding='utf-8'))
        keys = [(x['Path'], x['Name']) for x in labels]
        self.assertEqual(len(keys), len(set(keys)))
        self.assertTrue(any(x['Value'] == '格式刷' and x['Name'] == 'Label' for x in labels))

    def test_templates(self):
        templates=list((ROOT/'package/templates').glob('*'))
        self.assertEqual({p.suffix for p in templates},{'.ott','.ots','.otg'})
        for file in templates:
            with ZipFile(file) as archive:
                self.assertEqual(archive.namelist()[0],'mimetype')
                self.assertEqual(archive.getinfo('mimetype').compress_type,0)
                self.assertTrue(archive.read('mimetype').endswith(b'-template'))
                for name in ['content.xml','styles.xml','META-INF/manifest.xml']:
                    ET.fromstring(archive.read(name))

    def test_reproducible_archive(self):
        path = ROOT / 'dist/LibreOfficePlus-WPS界面配置包.zip'
        before = hashlib.sha256(path.read_bytes()).hexdigest()
        subprocess.run([sys.executable, str(ROOT / 'scripts/build.py')], check=True, stdout=subprocess.DEVNULL)
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), before)
        with ZipFile(path) as archive:
            for file in (ROOT / 'package').rglob('*'):
                if file.is_file():
                    self.assertEqual(archive.read('LibreOfficePlus/' + file.relative_to(ROOT / 'package').as_posix()), file.read_bytes())


if __name__ == '__main__':
    unittest.main()
