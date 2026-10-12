"""检查配置包中的 UI 结构、引用完整性和可重复构建。"""
import hashlib
import csv
from collections import Counter
import json
import os
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]


class PackageTests(unittest.TestCase):
    @unittest.skipUnless(os.name == 'nt', '图形入口检查需要 Windows Script Host')
    def test_graphical_launchers(self):
        with tempfile.TemporaryDirectory(prefix='LOPlus 图形入口 ') as temp:
            with ZipFile(ROOT / 'dist/LibreOfficePlus-WPS界面配置包.zip') as archive:
                archive.extractall(temp)
            folder = Path(temp) / 'LibreOfficePlus'
            marker = folder / 'gui-probe.json'
            (folder / 'installer-ui.ps1').write_text(
                'param([switch]$Restore)\n'
                '@{Restore=[bool]$Restore;Apartment=[Threading.Thread]::CurrentThread.ApartmentState.ToString()} | '
                'ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot "gui-probe.json") -Encoding UTF8\n',
                encoding='utf-8-sig')
            for name, restore in [('安装.vbs', False), ('恢复原界面.vbs', True)]:
                marker.unlink(missing_ok=True)
                data = (folder / name).read_bytes()
                data.decode('ascii')
                self.assertNotIn(b'\n', data.replace(b'\r\n', b''))
                # 将异步启动改为等待，仅用于捕获探针结果；隐藏方式保持不变。
                (folder / name).write_bytes(data.replace(b'shell.Run command, 0, False', b'shell.Run command, 0, True'))
                result = subprocess.run([str(Path(os.environ['SystemRoot']) / 'System32/cscript.exe'),
                                         '//nologo', str(folder / name)], capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0, repr(result.stdout + result.stderr))
                self.assertTrue(marker.exists(), repr(result.stdout + result.stderr))
                self.assertEqual(json.loads(marker.read_text('utf-8-sig')), {'Restore': restore, 'Apartment': 'STA'})

    @unittest.skipUnless(os.name == 'nt', '实际入口检查需要 Windows cmd.exe')
    def test_windows_launchers(self):
        # 解压最终交付文件，探针不修改个人 LibreOffice 配置。
        with tempfile.TemporaryDirectory(prefix='LOPlus 中文 路径 ') as temp:
            with ZipFile(ROOT / 'dist/LibreOfficePlus-WPS界面配置包.zip') as archive:
                archive.extractall(temp)
            folder = Path(temp) / 'LibreOfficePlus'
            probe = folder / 'probe.json'
            (folder / 'configure.ps1').write_text(
                'param([switch]$Restore,[string]$Modules,[string]$LibreOfficePath)\n'
                '@{Restore=[bool]$Restore;Modules=$Modules;Path=$LibreOfficePath;'
                'Directory=(Get-Location).Path} | ConvertTo-Json | '
                'Set-Content -LiteralPath (Join-Path $PSScriptRoot "probe.json") -Encoding UTF8\n'
                'exit 23\n', encoding='utf-8-sig')
            for name, restore in [('安装.cmd', False), ('恢复原界面.cmd', True)]:
                data = (folder / name).read_bytes()
                data.decode('ascii')
                self.assertNotIn(b'\n', data.replace(b'\r\n', b''))
                for page in [936, 65001]:
                    with self.subTest(entry=name, codepage=page):
                        probe.unlink(missing_ok=True)
                        # 在其他工作目录启动，验证入口自己切换到解压目录。
                        command = f'chcp {page} >nul & call "{folder / name}" -Modules Writer,Calc -LibreOfficePath "C:\\Apps with spaces\\LibreOffice"'
                        result = subprocess.run(f'cmd.exe /d /s /c "{command}"',
                                                cwd=ROOT, input=b'\r\n', capture_output=True, timeout=30)
                        self.assertEqual(result.returncode, 23, repr(result.stdout + result.stderr))
                        self.assertTrue(probe.exists(), repr(result.stdout + result.stderr))
                        actual = json.loads(probe.read_text('utf-8-sig'))
                        self.assertTrue(folder.samefile(actual.pop('Directory')))
                        self.assertEqual(actual, {'Restore': restore, 'Modules': 'Writer,Calc',
                                                  'Path': r'C:\Apps with spaces\LibreOffice'})

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

    def test_release_scope(self):
        sys.path.insert(0, str(ROOT / 'scripts'))
        from check_release import verify
        name = 'LibreOfficePlus-WPS界面配置包.zip'
        data = (ROOT / 'dist' / name).read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        version = json.loads((ROOT / 'package/version.json').read_text('utf8'))['Version']
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            (folder / name).write_bytes(data)
            (folder / 'release.json').write_text(json.dumps({'commit':'a' * 40, 'sha256':digest, 'file':name, 'version':version}), 'utf8')
            (folder / 'SHA256SUMS.txt').write_text(f'{digest}  {name}\n', 'utf8')
            verify(folder, 'a' * 40)
            with self.assertRaises(AssertionError):
                verify(folder, 'b' * 40)
            (folder / 'unexpected.txt').write_text('private', 'utf8')
            with self.assertRaises(AssertionError):
                verify(folder, 'a' * 40)
            (folder / 'unexpected.txt').unlink()
            (folder / name).write_bytes(data + b'changed')
            with self.assertRaises(AssertionError):
                verify(folder, 'a' * 40)

    def test_popup_commands_and_groups(self):
        ns = '{http://openoffice.org/2001/menu}'
        specs = json.loads((ROOT / 'config/popups.json').read_text('utf8'))
        labels = json.loads((ROOT / 'config/popup-labels.json').read_text('utf8'))
        manifest = json.loads((ROOT / 'package/profile-files.json').read_text('utf8'))
        self.assertEqual(len(manifest), len(specs))
        for entry in manifest:
            path = entry['Path']
            self.assertRegex(path, r'^config/soffice.cfg/modules/(swriter|scalc|sdraw)/popupmenu/[a-z0-9_]+\.xml$')
            module, name = entry['Module'], Path(path).stem
            source = ET.parse(ROOT / 'vendor/libreoffice' / module / 'popupmenu' / (name + '.xml')).getroot()
            output = ET.parse(ROOT / 'package/profile' / path).getroot()
            commands = lambda menu: Counter(n.get(ns + 'id') for n in menu.iter() if n.get(ns + 'id'))
            self.assertEqual(commands(source), commands(output), path)
            for node in output.iter():
                command = node.get(ns + 'id', '').removeprefix('.uno:')
                if command in labels:
                    self.assertEqual(node.get(ns + 'label'), labels[command])
            for menu in output.iter(ns + 'menupopup'):
                tags = [c.tag for c in menu]
                if tags:
                    self.assertNotEqual(tags[0], ns + 'menuseparator')
                    self.assertNotEqual(tags[-1], ns + 'menuseparator')
                self.assertFalse(any(a == b == ns + 'menuseparator' for a,b in zip(tags,tags[1:])))
            expected = ['.uno:' + c for g in specs[module + '/' + name]['groups'] for c in g]
            actual = [c.get(ns + 'id') for c in output if c.get(ns + 'id') in expected]
            self.assertEqual(actual, [c for c in expected if c in actual])
            # 动态菜单必须仍为空，由原生控制器按选区生成。
            for node in source.iter(ns + 'menu'):
                if not list(node):
                    dynamic = output.find('.//*[@' + ns + 'id="' + node.get(ns + 'id') + '"]')
                    self.assertIsNotNone(dynamic)
                    self.assertEqual(list(dynamic), [])

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

    def test_shortcuts(self):
        entries = json.loads((ROOT / 'config/shortcuts.json').read_text('utf8'))
        self.assertEqual(len({e['Path'] for e in entries}), len(entries))
        self.assertEqual(len(entries), 22)
        for entry in entries:
            self.assertRegex(entry['Path'], r'^/org.openoffice.Office.Accelerators/PrimaryKeys/Modules/com\.sun\.star\.(text\.TextDocument|sheet\.SpreadsheetDocument|drawing\.DrawingDocument)/[A-Z0-9]+(?:_(?:SHIFT|MOD1|MOD2))*$')
            self.assertTrue(entry['Value'].startswith('.uno:'))
            self.assertEqual(entry['Language'], 'en-US')
        with (ROOT / 'package/快捷键对照表.csv').open(encoding='utf-8-sig', newline='') as file:
            rows = list(csv.reader(file))
        self.assertEqual(len(rows), len(entries) + 1)

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
