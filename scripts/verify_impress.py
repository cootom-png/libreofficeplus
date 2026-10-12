"""在专用实例中验证演示入口、快捷键、幻灯片与 PPTX 往返；不接触个人文档。"""
import argparse
import json
import sys
from pathlib import Path
import uno
from com.sun.star.lang import DisposedException
from com.sun.star.uno import RuntimeException
from verify_shortcuts import verify as verify_keys, key_event

ROOT = Path(__file__).resolve().parents[1]


def verify(context, output):
    manager = context.ServiceManager
    actual = manager.createInstanceWithContext('com.sun.star.util.PathSubstitution', context).substituteVariables('$(user)', True)
    if not Path(uno.fileUrlToSystemPath(actual)).resolve().is_relative_to(ROOT / '.test-work') or not output.resolve().is_relative_to(ROOT / '.test-work'):
        raise RuntimeError('只允许专用测试配置目录')
    desktop = manager.createInstanceWithContext('com.sun.star.frame.Desktop', context)
    helper = manager.createInstanceWithContext('com.sun.star.frame.DispatchHelper', context)
    provider = manager.createInstanceWithContext('com.sun.star.configuration.ConfigurationProvider', context)
    arg = uno.createUnoStruct('com.sun.star.beans.PropertyValue', Name='nodepath', Value='/org.openoffice.Office.UI.DrawImpressCommands/UserInterface/Commands')
    aliases = provider.createInstanceWithArguments('com.sun.star.configuration.ConfigurationAccess', (arg,))

    def target(command):
        # 原生 UI 根据 TargetURL 解析别名；直接 UNO 派发和快捷键须使用实际目标。
        if aliases.hasByName(command):
            value = aliases.getByName(command).getPropertyValue('TargetURL')
            if value:
                return value
        return command

    records, docs = [], []
    output.mkdir(parents=True, exist_ok=True)

    def props(**values):
        return tuple(uno.createUnoStruct('com.sun.star.beans.PropertyValue', Name=k, Value=v) for k, v in values.items())

    def open_doc(url, **values):
        doc = desktop.loadComponentFromURL(url, '_blank', 0, props(Hidden=True, **values))
        docs.append(doc)
        return doc

    def check(name, condition):
        records.append({'模块': 'Impress', '操作': name, '通过': bool(condition)})
        if not condition:
            raise AssertionError(name)

    def dispatch(command):
        helper.executeDispatch(doc.CurrentController.Frame, target('.uno:' + command), '', 0, ())

    try:
        doc = open_doc('private:factory/simpress')
        frame = doc.CurrentController.Frame
        layout = json.loads((ROOT / 'config/layout.json').read_text('utf8'))['modules']['simpress']
        home = json.loads((ROOT / 'config/home.json').read_text('utf8'))['simpress']['quick_rows']
        commands = {entry['command'] for groups in layout.values() for group in groups for entry in group}
        for row in home:
            for entry in row:
                commands.update(x['command'] for x in entry.get('menu', [entry]) if 'command' in x)
        for command in sorted(commands):
            resolved = target(command)
            url = uno.createUnoStruct('com.sun.star.util.URL', Complete=resolved, Protocol='.uno:', Path=resolved[5:])
            check('入口可派发 ' + command, frame.queryDispatch(url, '', 0) is not None)
        records.extend(x for x in verify_keys(context) if x['模块'] == 'Impress')
        supplier = manager.createInstanceWithContext('com.sun.star.ui.ModuleUIConfigurationManagerSupplier', context)
        keys = supplier.getUIConfigurationManager('com.sun.star.presentation.PresentationDocument').getShortCutManager()
        # 直接使用实际键位映射，不能靠测试解析别名掩盖错误配置。
        helper.executeDispatch(frame, keys.getCommandByKeyEvent(key_event('M_MOD1')), '', 0, ())
        check('新建幻灯片', doc.DrawPages.Count == 2)
        page = doc.CurrentController.CurrentPage
        page.Name = '测试幻灯片'
        while page.Count:
            page.remove(page.getByIndex(0))
        shape = doc.createInstance('com.sun.star.drawing.TextShape')
        page.add(shape)
        shape.Position = uno.createUnoStruct('com.sun.star.awt.Point', X=2000, Y=2000)
        shape.Size = uno.createUnoStruct('com.sun.star.awt.Size', Width=10000, Height=3000)
        shape.String = '演示操作验证'
        dispatch('DuplicateSlide')
        check('复制幻灯片保留内容', doc.DrawPages.Count == 3 and any(getattr(s, 'String', '') == shape.String for s in doc.CurrentController.CurrentPage))
        dispatch('HideSlide')
        records.append({'模块': 'Impress', '操作': '隐藏幻灯片', '通过': None, '状态': '需可见缩略图选区复核', '无界面观察': doc.CurrentController.CurrentPage.Visible})
        dispatch('ShowSlide')
        records.append({'模块': 'Impress', '操作': '取消隐藏', '通过': None, '状态': '需可见缩略图选区复核'})
        dispatch('DeleteSlide')
        check('删除幻灯片', doc.DrawPages.Count == 2)
        dispatch('Undo')
        check('撤销删除', doc.DrawPages.Count == 3)
        dispatch('Redo')
        check('重做删除', doc.DrawPages.Count == 2)
        dispatch('SlideMasterPage')
        check('母版视图', doc.CurrentController.IsMasterPageMode)
        dispatch('CloseMasterView')
        check('关闭母版视图', not doc.CurrentController.IsMasterPageMode)
        doc.CurrentController.CurrentPage = page
        shapes = manager.createInstanceWithContext('com.sun.star.drawing.ShapeCollection', context)
        shapes.add(shape)
        rect = doc.createInstance('com.sun.star.drawing.RectangleShape')
        page.add(rect)
        shapes.add(rect)
        doc.CurrentController.select(shapes)
        dispatch('FormatGroup')
        check('对象组合', page.Count == 1)
        dispatch('FormatUngroup')
        check('取消组合', page.Count == 2)
        before = page.Count
        dispatch('GridVisible')
        dispatch('GridVisible')
        check('网格切换保留内容', page.Count == before and shape.String == '演示操作验证')
        for suffix, filter_name in [('odp', 'impress8'), ('pptx', 'Impress MS PowerPoint 2007 XML'), ('pdf', 'impress_pdf_Export')]:
            artifact = output / ('演示验证.' + suffix)
            doc.storeToURL(uno.systemPathToFileUrl(str(artifact)), props(FilterName=filter_name, Overwrite=True))
            check('导出 ' + suffix, artifact.exists() and artifact.stat().st_size > 100)
            if suffix != 'pdf':
                reopened = open_doc(uno.systemPathToFileUrl(str(artifact)))
                strings = [s.String for p in reopened.DrawPages for s in p if hasattr(s, 'String')]
                check(suffix + ' 往返内容与页数', reopened.DrawPages.Count == 2 and '演示操作验证' in strings)
        template = open_doc(uno.systemPathToFileUrl(str(ROOT / 'package/templates/WPS习惯演示.otp')), AsTemplate=True)
        page = template.DrawPages.getByIndex(0)
        text = template.createInstance('com.sun.star.drawing.TextShape')
        page.add(text)
        text.String = '新文档字体'
        check('16:9 空白模板', page.Width == 28000 and page.Height == 15750)
        check('模板默认文字', text.CharHeight == 24 and text.CharFontNameAsian == '宋体')
    finally:
        (output / '演示验收.json').write_text(json.dumps(records, ensure_ascii=False, indent=2) + '\n', 'utf8', newline='\n')
        for doc in docs:
            try:
                doc.close(True)
            except DisposedException:
                pass
            except RuntimeException as error:
                if 'illegal object given!' not in str(error):
                    raise
    return records


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf8')
    sys.stderr.reconfigure(encoding='utf8')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pipe', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    local = uno.getComponentContext()
    context = local.ServiceManager.createInstanceWithContext('com.sun.star.bridge.UnoUrlResolver', local).resolve(
        'uno:pipe,name=' + args.pipe + ';urp;StarOffice.ComponentContext')
    results = verify(context, args.output)
    print(f'{sum(x["通过"] is True for x in results)} 项演示检查通过；{sum(x["通过"] is None for x in results)} 项需可见窗口复核。')
