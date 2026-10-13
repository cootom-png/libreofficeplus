"""核对固定上游源码并检查补丁适用性；不编译或安装 LibreOffice 本体。"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
PATCH_DIR = ROOT / 'upstream' / 'notebookbar-spacing'


def verify(base, manifest, cache):
    with tempfile.TemporaryDirectory(prefix='libreoffice-tab-spacing-') as directory:
        target = Path(directory)
        for name, expected in base['files'].items():
            if cache:
                data = (cache / base['name'] / name).read_bytes()
            else:
                url = f"https://raw.githubusercontent.com/LibreOffice/core/{base['commit']}/{name}"
                with urllib.request.urlopen(url, timeout=30) as response:
                    data = response.read()
            if hashlib.sha256(data).hexdigest() != expected:
                raise ValueError(f"{base['name']}: {name} 来源校验失败")
            source = target / name
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_bytes(data)

        patch = str(PATCH_DIR / manifest['patch'])
        stats = subprocess.run(['git', 'apply', '--numstat', patch], cwd=target,
                               check=True, capture_output=True, text=True).stdout
        changed_paths = {line.split('\t', 2)[2] for line in stats.splitlines()}
        if changed_paths != set(manifest['changed_paths']):
            raise ValueError(f"{base['name']}: 补丁修改范围与清单不一致")
        subprocess.run(['git', 'apply', '--check', '--whitespace=error-all', patch],
                       cwd=target, check=True)
        subprocess.run(['git', 'apply', '--whitespace=error-all', patch], cwd=target, check=True)
        print(f"通过 {base['name']} / {base['commit']}: 来源校验、补丁检查和试应用", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, help='使用按基线名称存放的源码，仍核对 SHA-256')
    args = parser.parse_args()
    manifest = json.loads((PATCH_DIR / 'source.json').read_text(encoding='utf8'))
    for base in manifest['bases']:
        verify(base, manifest, args.cache)
    print('本检查未执行 C++ 编译、CppUnit 或实际界面验收。')


if __name__ == '__main__':
    main()
