"""读取隔离 LibreOffice 实例的实际更新开关；不升级或打开个人文档。"""
import argparse
import json
import time
from pathlib import Path
import uno


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--pipe', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--restored', action='store_true')
    parser.add_argument('--initialize', action='store_true')
    parser.add_argument('--profile', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    local = uno.getComponentContext()
    resolver = local.ServiceManager.createInstanceWithContext('com.sun.star.bridge.UnoUrlResolver', local)
    for attempt in range(120):
        try:
            context = resolver.resolve(f'uno:pipe,name={args.pipe};urp;StarOffice.ComponentContext')
            break
        except Exception:
            if attempt == 119:
                raise
            time.sleep(0.25)
    manager = context.ServiceManager
    desktop = manager.createInstanceWithContext('com.sun.star.frame.Desktop', context)
    provider = manager.createInstanceWithContext('com.sun.star.configuration.ConfigurationProvider', context)
    results = []
    try:
        substitution = manager.createInstanceWithContext('com.sun.star.util.PathSubstitution', context)
        user = Path(uno.fileUrlToSystemPath(substitution.substituteVariables('$(user)', True)))
        assert user.resolve() == (args.profile / 'user').resolve(), '未连接到指定隔离配置'
        prop = uno.createUnoStruct('com.sun.star.beans.PropertyValue', Name='nodepath', Value='/org.openoffice.Setup/Product')
        product = provider.createInstanceWithArguments('com.sun.star.configuration.ConfigurationAccess', (prop,))
        actual_version = product.getPropertyValue('ooSetupVersionAboutBox')
        assert actual_version == args.version, f'实际版本 {actual_version} 与预期 {args.version} 不符'
        for path, names in [('/org.openoffice.Office.Jobs/Jobs/UpdateCheck/Arguments', ['AutoCheckEnabled', 'AutoDownloadEnabled']),
                            ('/org.openoffice.Office.Update/Update', ['Enabled'])]:
            prop = uno.createUnoStruct('com.sun.star.beans.PropertyValue', Name='nodepath', Value=path)
            node = provider.createInstanceWithArguments('com.sun.star.configuration.ConfigurationAccess', (prop,))
            for name in names:
                value = node.getPropertyValue(name)
                results.append({'version': actual_version, 'restored': args.restored, 'path': path,
                                'name': name, 'value': value, 'passed': args.initialize or value is args.restored})
        args.output.write_text(json.dumps(results, ensure_ascii=False, indent=2) + '\n', 'utf8')
        assert all(row['passed'] for row in results), results
    finally:
        desktop.terminate()


if __name__ == '__main__':
    main()
