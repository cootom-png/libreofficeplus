"""在专用独立实例中检查新增入口的实际行为；仅使用合成文档。"""
import argparse
import json
import sys
from pathlib import Path
import uno

ROOT = Path(__file__).resolve().parents[1]


def verify(context, visible=False):
    manager = context.ServiceManager
    user = manager.createInstanceWithContext('com.sun.star.util.PathSubstitution', context).substituteVariables('$(user)', True)
    Path(uno.fileUrlToSystemPath(user)).resolve().relative_to((ROOT / '.test-work').resolve())
    desktop = manager.createInstanceWithContext('com.sun.star.frame.Desktop', context)
    helper = manager.createInstanceWithContext('com.sun.star.frame.DispatchHelper', context)
    clipboard = manager.createInstanceWithContext('com.sun.star.datatransfer.clipboard.SystemClipboard', context)
    previous = clipboard.getContents()
    docs, results = [], []

    def props(**values):
        return tuple(uno.createUnoStruct('com.sun.star.beans.PropertyValue', Name=k, Value=v) for k, v in values.items())

    def check(name, condition):
        if not condition:
            raise AssertionError(name)
        results.append({'检查': name, '通过': True})

    def open_doc(module):
        doc = desktop.loadComponentFromURL('private:factory/' + module, '_blank', 0, props(Hidden=not visible))
        docs.append(doc)
        return doc

    def dispatch(doc, command):
        helper.executeDispatch(doc.CurrentController.Frame, command, '', 0, ())

    try:
        calc = open_doc('scalc'); sheet = calc.Sheets[0]; controller = calc.CurrentController
        cell = sheet.getCellRangeByName
        cell('A1').String = 'example'; cell('B1').Value = 7
        cell('C1').Formula = '=2+3'; cell('D1').Formula = '="result"'
        cell('E1').Value = 45000
        cell('E1').NumberFormat = calc.NumberFormats.getStandardFormat(2, uno.createUnoStruct('com.sun.star.lang.Locale', Language='en', Country='US'))
        cell('A1:E1').CharWeight = 150
        controller.select(cell('A1:E1')); dispatch(calc, '.uno:Copy')
        controller.select(cell('A3')); dispatch(calc, '.uno:InsertContents?Flags:string=SVD')
        check('粘贴值保留文本', cell('A3').String == 'example')
        check('粘贴值保留数字', cell('B3').Value == 7)
        check('公式转为数字结果', cell('C3').Value == 5 and cell('C3').Type.value == 'VALUE')
        check('公式转为文本结果', cell('D3').String == 'result' and cell('D3').Type.value == 'TEXT')
        check('日期保留序列值', cell('E3').Value == 45000)
        check('粘贴值保留目标格式', cell('A3:E3').CharWeight == 100)
        cell('A5:E5').setDataArray((('keep', 9, 8, 7, 6),))
        controller.select(cell('A5')); dispatch(calc, '.uno:InsertContents?Flags:string=T')
        check('粘贴格式保留目标内容', cell('A5:E5').getDataArray() == (('keep', 9., 8., 7., 6.),))
        check('粘贴格式应用文字格式', cell('A5:E5').CharWeight == 150)
        check('粘贴格式应用日期格式', cell('E5').NumberFormat == cell('E1').NumberFormat)
        dispatch(calc, '.uno:Undo'); check('粘贴格式可撤销', cell('A5:E5').CharWeight == 100)
        controller.select(cell('A7')); dispatch(calc, '.uno:PasteOnlyFormula')
        check('仅公式保留公式', cell('C7').Type.value == 'FORMULA' and cell('D7').Type.value == 'FORMULA')
        check('仅公式不复制常量', cell('A7').String == '' and cell('B7').String == '')
        descriptions = manager.createInstanceWithContext('com.sun.star.frame.UICommandDescription', context)
        for module, command, expected in [('sheet.SpreadsheetDocument', 'InsertSheetFromFile', '从文件导入工作表…'), ('text.TextDocument', 'InsertObject', '嵌入对象…'), ('text.TextDocument', 'SidebarDeck.InspectorDeck', '样式检查')]:
            values = {p.Name:p.Value for p in descriptions.getByName('com.sun.star.' + module).getByName('.uno:' + command)}
            check(command + ' 有效名称', values['Label'] == expected)
        writer = open_doc('swriter'); writer.Text.String = 'Example paragraph'
        writer.setModified(False)
        dispatch(writer, '.uno:SidebarDeck.InspectorDeck')
        check('样式检查入口不改写内容', writer.Text.String == 'Example paragraph' and not writer.isModified())
        draw = open_doc('sdraw')
        url = 'private:resource/menubar/menubar'
        layout = draw.CurrentController.Frame.LayoutManager
        provider = manager.createInstanceWithContext('com.sun.star.configuration.ConfigurationProvider', context)
        config = provider.createInstanceWithArguments('com.sun.star.configuration.ConfigurationAccess', props(nodepath='/org.openoffice.Office.UI.ToolbarMode/Applications/Draw/Modes/Tabbed'))
        check('Draw 简洁布局设置生效', not config.HasMenubar)
        menu_url = uno.createUnoStruct('com.sun.star.util.URL', Complete='.uno:Menubar', Protocol='.uno:', Path='Menubar')
        check('Draw 菜单栏命令可用', draw.CurrentController.Frame.queryDispatch(menu_url, '', 0) is not None)
        if visible:
            check('Draw 初始收起传统菜单栏', not layout.isElementVisible(url))
            dispatch(draw, '.uno:Menubar')
            check('Draw 菜单栏可重新显示', layout.isElementVisible(url))
            dispatch(draw, '.uno:Menubar')
            check('Draw 菜单栏可再次收起', not layout.isElementVisible(url))
    finally:
        if previous is not None:
            clipboard.setContents(previous, None)
        for doc in reversed(docs):
            doc.close(True)
    return results


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf8')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pipe', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--visible', action='store_true', help='仅用于可见的独立测试实例，另检查菜单栏显示与收起')
    args = parser.parse_args()
    local = uno.getComponentContext()
    resolver = local.ServiceManager.createInstanceWithContext('com.sun.star.bridge.UnoUrlResolver', local)
    context = resolver.resolve('uno:pipe,name=' + args.pipe + ';urp;StarOffice.ComponentContext')
    records = verify(context, args.visible)
    args.output.write_text(json.dumps(records, ensure_ascii=False, indent=2) + '\n', 'utf8')
    print(f'{len(records)} 项常用入口行为检查通过。')
