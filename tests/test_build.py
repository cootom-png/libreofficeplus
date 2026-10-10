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
        for module in ["swriter", "scalc"]:
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

    def test_labels(self):
        labels = json.loads((ROOT / 'package/设置清单.json').read_text(encoding='utf-8'))
        keys = [(x['Path'], x['Name']) for x in labels]
        self.assertEqual(len(keys), len(set(keys)))
        self.assertTrue(any(x['Value'] == '格式刷' and x['Name'] == 'Label' for x in labels))

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
