"""在独立测试配置中检查 Material 配色的有效值、原生样式与恢复。"""
import argparse
import json
import time
from pathlib import Path
import uno
from com.sun.star.document.MacroExecMode import USE_CONFIG_REJECT_CONFIRMATION
from com.sun.star.lang import DisposedException

ROOT = Path(__file__).resolve().parents[1]


def contrast(first, second):
    def luminance(color):
        channels = [(color >> shift & 255) / 255 for shift in (16, 8, 0)]
        linear = [v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in channels]
        return sum(v * w for v, w in zip(linear, (0.2126, 0.7152, 0.0722)))
    dark, light = sorted((luminance(first), luminance(second)))
    return (light + 0.05) / (dark + 0.05)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pipe', required=True)
    parser.add_argument('--profile', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--baseline', type=Path)
    parser.add_argument('--configured', action='store_true')
    parser.add_argument('--visible', action='store_true')
    parser.add_argument('--native-styles', action='store_true', help='核验原生 Windows 样式颜色，需以非 headless 实例运行')
    parser.add_argument('--hold', type=int, default=0, help='保留独立预览窗口的秒数，最多 180 秒')
    args = parser.parse_args()
    assert args.profile.resolve().is_relative_to(ROOT / '.test-work'), '仅允许独立测试配置'
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
    prop = lambda path: uno.createUnoStruct('com.sun.star.beans.PropertyValue', Name='nodepath', Value=path)
    access = lambda path: provider.createInstanceWithArguments('com.sun.star.configuration.ConfigurationAccess', (prop(path),))
    user = manager.createInstanceWithContext('com.sun.star.util.PathSubstitution', context).substituteVariables('$(user)', True)
    assert Path(uno.fileUrlToSystemPath(user)).resolve() == (args.profile / 'user').resolve(), '连接到了错误配置'
    result = {'version': access('/org.openoffice.Setup/Product').ooSetupVersionAboutBox, 'settings': [], 'styles': []}
    wanted = json.loads(args.baseline.read_text('utf8'))['settings'] if args.baseline else None
    documents = []
    try:
        for index, setting in enumerate(json.loads((ROOT / 'config/appearance.json').read_text('utf8'))):
            value = access(setting['Path']).getPropertyValue(setting['Name'])
            if args.configured:
                assert str(value).lower() == setting['Value'].lower(), (setting['Path'], value)
            if wanted:
                assert value == wanted[index]['value'], (setting['Path'], value, wanted[index]['value'])
            result['settings'].append({'path': setting['Path'], 'name': setting['Name'], 'value': value, 'passed': True})
        if args.configured:
            for module in ['swriter', 'scalc', 'sdraw', 'simpress']:
                doc = desktop.loadComponentFromURL('private:factory/' + module, '_blank', 0,
                    (uno.createUnoStruct('com.sun.star.beans.PropertyValue', Name='Hidden', Value=True),
                     uno.createUnoStruct('com.sun.star.beans.PropertyValue', Name='MacroExecutionMode', Value=USE_CONFIG_REJECT_CONFIRMATION)))
                documents.append(doc)
                doc.setTitle('LibreOfficePlus Material Preview ' + module)
                if args.visible:
                    doc.CurrentController.Frame.ContainerWindow.setVisible(True)
                styles = doc.CurrentController.Frame.ContainerWindow.StyleSettings
                values = {name: getattr(styles, name) for name in ['FaceColor', 'WindowColor', 'MenuColor', 'MenuTextColor', 'MenuHighlightColor', 'MenuHighlightTextColor', 'FieldColor']}
                # 可见 Windows 实例还核验实际绘制使用的样式，不能只检查磁盘配置。
                if args.visible or args.native_styles:
                    # Windows 原生菜单的选中颜色仍可能由系统绘制，单独记录，不冒充已统一。
                    for name, color in {'FaceColor': 'F8FAFD', 'WindowColor': 'F8FAFD', 'MenuColor': 'FFFFFF', 'MenuTextColor': '1F1F1F', 'FieldColor': 'FFFFFF', 'MenuHighlightTextColor': '000000'}.items():
                        assert values[name] == int(color, 16), (module, name, values[name], color)
                    assert contrast(values['MenuHighlightColor'], values['MenuHighlightTextColor']) >= 4.5, (module, '菜单选中文字对比度不足')
                result['styles'].append({'module': module, 'values': values, 'verified': args.visible or args.native_styles})
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', 'utf8')
        if args.visible:
            print('可见窗口配色检查通过，正在保留独立预览。', flush=True)
            time.sleep(min(max(args.hold, 0), 180))
    finally:
        for doc in documents:
            try:
                doc.setModified(False)
            except DisposedException:
                pass
        try:
            if not desktop.terminate():
                raise RuntimeError('独立预览未能退出，请检查测试实例')
        except DisposedException:
            pass


if __name__ == '__main__':
    main()
