"""只允许发布已构建的配置包、校验清单与公开版本信息。"""
import hashlib
import json
import sys
from pathlib import Path
from zipfile import ZipFile


def verify(folder, commit):
    name = 'LibreOfficePlus-WPS界面配置包.zip'
    assert {p.name for p in folder.iterdir()} == {name, 'SHA256SUMS.txt', 'release.json'}, '发布文件超出白名单'
    info = json.loads((folder / 'release.json').read_text('utf-8-sig'))
    assert info['commit'] == commit and info['file'] == name, '版本信息不匹配'
    digest = hashlib.sha256((folder / name).read_bytes()).hexdigest()
    assert info['sha256'] == digest, '配置包校验失败'
    assert (folder / 'SHA256SUMS.txt').read_text('utf-8-sig').strip() == f'{digest}  {name}'
    with ZipFile(folder / name) as archive:
        assert json.loads(archive.read('LibreOfficePlus/version.json'))['Version'] == info['version']
        # ZIP 必须逐字匹配该提交的 package/，排除本机资料与额外路径。
        root = Path(__file__).resolve().parents[1] / 'package'
        expected = {'LibreOfficePlus/' + p.relative_to(root).as_posix(): p for p in root.rglob('*') if p.is_file()}
        assert len(archive.namelist()) == len(expected) and set(archive.namelist()) == set(expected)
        assert all(archive.read(name) == file.read_bytes() for name, file in expected.items())


if __name__ == '__main__':
    verify(Path(sys.argv[1]), sys.argv[2])
