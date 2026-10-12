"""仅在已确认的独立实例中，用模拟文档检查格式操作的布局副作用。"""
import argparse
import json
import re
import sys
from pathlib import Path
import uno

parser = argparse.ArgumentParser()
parser.add_argument('--pipe', required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--configured', action='store_true', help='验证行距命令来自已安装配置包的有效键位')
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
sys.stdout.reconfigure(encoding='utf8')
local = uno.getComponentContext()
resolver = local.ServiceManager.createInstanceWithContext('com.sun.star.bridge.UnoUrlResolver', local)
context = resolver.resolve(f'uno:pipe,name={args.pipe};urp;StarOffice.ComponentContext')
manager = context.ServiceManager
desktop = manager.createInstanceWithContext('com.sun.star.frame.Desktop', context)
helper = manager.createInstanceWithContext('com.sun.star.frame.DispatchHelper', context)
user = manager.createInstanceWithContext('com.sun.star.util.PathSubstitution', context).substituteVariables('$(user)', True)
test_root = Path(__file__).resolve().parents[1] / '.test-work'
profile = Path(uno.fileUrlToSystemPath(user)).resolve().relative_to(test_root.resolve())
assert profile.parts[0].startswith('layout-audit-'), '拒绝连接个人配置'
results, observations, documents = [], [], []
complete = False

def props(**values):
    return tuple(uno.createUnoStruct('com.sun.star.beans.PropertyValue', Name=k, Value=v) for k, v in values.items())

def open_doc(url):
    doc = desktop.loadComponentFromURL(url, '_blank', 0, props(Hidden=True, AsTemplate=True, MacroExecutionMode=4))
    documents.append(doc)
    return doc

def dispatch(doc, command, **values):
    helper.executeDispatch(doc.CurrentController.Frame, '.uno:' + command, '', 0, props(**values))

def check(module, name, condition, actual=None):
    results.append({'模块': module, '检查': name, '通过': bool(condition), '实际': actual})
    print(('通过' if condition else '失败') + ' ' + module + ' / ' + name, flush=True)

def pages(doc, name):
    dest = args.output / (name + '.pdf')
    doc.storeToURL(uno.systemPathToFileUrl(str(dest.resolve())), props(FilterName='writer_pdf_Export', Overwrite=True))
    return len(re.findall(rb'/Type\s*/Page\b', dest.read_bytes()))

def writer_form():
    doc = open_doc('private:factory/swriter')
    doc.Text.String = '模拟表单标题\r表格前的说明\r'
    table = doc.createInstance('com.sun.star.text.TextTable')
    table.initialize(6, 3)
    doc.Text.insertTextContent(doc.Text.End, table, False)
    table.HoriOrient = 0
    table.Width = 14000
    table.getCellByName('A1').String = '项目'
    table.getCellByName('B1').String = '数量'
    table.getCellByName('C1').String = '备注'
    for row in range(2, 7):
        table.getCellByName('A' + str(row)).String = '测试项目 ' + str(row)
        table.getCellByName('B' + str(row)).Value = row * 2
        table.getCellByName('C' + str(row)).String = '模拟数据'
    frame = doc.createInstance('com.sun.star.text.TextFrame')
    frame.AnchorType = uno.Enum('com.sun.star.text.TextContentAnchorType', 'AT_PARAGRAPH')
    frame.FrameIsAutomaticHeight = False
    frame.Width, frame.Height = 5000, 1500
    doc.Text.insertTextContent(doc.Text.Start, frame, False)
    frame.String = '普通文字框'
    frame.HoriOrient, frame.VertOrient = 0, 0
    frame.HoriOrientPosition, frame.VertOrientPosition = 9000, 1500
    return doc, table, frame

def geometry(doc, table, frame):
    return (table.Width, table.LeftMargin, table.RightMargin, table.HoriOrient,
            frame.getSize().Width, frame.getSize().Height, str(frame.AnchorType), frame.HoriOrientPosition,
            frame.VertOrientPosition, doc.TextFrames.Count, doc.DrawPage.Count)

def narrow_form():
    doc=open_doc('private:factory/swriter')
    page=doc.StyleFamilies.getByName('PageStyles').getByName('Standard')
    page.Width=21000;page.Height=29700;page.TopMargin=2000;page.BottomMargin=2000
    doc.Text.String='模拟标题\r\r'
    e=doc.Text.createEnumeration();e.nextElement();anchor=e.nextElement()
    anchor.ParaStyleName='Text body'
    anchor.ParaLineSpacing=uno.createUnoStruct('com.sun.star.style.LineSpacing',Mode=3,Height=300)
    frame=doc.createInstance('com.sun.star.text.TextFrame')
    frame.AnchorType=uno.Enum('com.sun.star.text.TextContentAnchorType','AS_CHARACTER')
    frame.FrameIsAutomaticHeight=False;frame.Width=342;frame.Height=5516
    doc.Text.insertTextContent(anchor.Start,frame,False);frame.String='模拟文字一二三四五'
    table=doc.createInstance('com.sun.star.text.TextTable');table.initialize(22,2)
    doc.Text.insertTextContent(doc.Text.End,table,False);table.HoriOrient=0;table.Width=14000
    for index in range(table.Rows.Count):
        row=table.Rows.getByIndex(index);row.IsAutoHeight=False;row.Height=1000
        table.getCellByName('A'+str(index+1)).String='模拟行 '+str(index+1)
    return doc, anchor, frame, table

def frame_state(doc, anchor, frame, table, name):
    return {'页数': pages(doc, name), '框数量': doc.TextFrames.Count,
            '框宽': frame.Width, '框高': frame.Height, '表宽': table.Width,
            '行距': [anchor.ParaLineSpacing.Mode, anchor.ParaLineSpacing.Height]}


def observe_narrow_frames():
    cases = [('标题1', 'StyleApply', {'Style': 'Heading 1', 'FamilyName': 'ParagraphStyles'}),
             ('正文', 'StyleApply', {'Style': 'Text body', 'FamilyName': 'ParagraphStyles'}),
             ('默认段落', 'StyleApply', {'Style': 'Standard', 'FamilyName': 'ParagraphStyles'}),
             ('清除格式', 'ResetAttributes', {}), ('单倍行距', 'SpacePara1', {}),
             ('双倍行距', 'SpacePara2', {}), ('加粗', 'Bold', {}), ('居中', 'CenterPara', {})]
    key_commands = {}
    if args.configured:
        from verify_shortcuts import key_event
        supplier = manager.createInstanceWithContext('com.sun.star.ui.ModuleUIConfigurationManagerSupplier', context)
        shortcuts = supplier.getUIConfigurationManager('com.sun.star.text.TextDocument').getShortCutManager()
        for command, key in [('SpacePara1', '1_MOD1'), ('SpacePara2', '2_MOD1')]:
            actual = shortcuts.getCommandByKeyEvent(key_event(key))
            assert actual == '.uno:' + command, (key, actual)
            key_commands[command] = actual.removeprefix('.uno:')
    for selected in [False, True]:
        for index, (label, command, values) in enumerate(cases):
            doc, anchor, frame, table = narrow_form()
            name = f'risk-{int(selected)}-{index}'
            before = frame_state(doc, anchor, frame, table, name + '-before')
            cursor = doc.Text.createTextCursorByRange(anchor.Start)
            if selected:
                cursor.gotoEndOfParagraph(True)
            doc.CurrentController.select(cursor)
            dispatch(doc, key_commands.get(command, command), **values)
            after = frame_state(doc, anchor, frame, table, name + '-after')
            expected_reflow = command not in ['Bold', 'CenterPara'] and (command != 'ResetAttributes' or selected)
            preserved = all(before[k] == after[k] for k in ['框数量', '框宽', '框高', '表宽'])
            matches = preserved and before['页数'] == 1 and after['页数'] == (2 if expected_reflow else 1)
            observations.append({'选区': '整段' if selected else '光标', '操作': label,
                                 '操作前': before, '操作后': after,
                                 '风险重现': after['页数'] > before['页数'], '符合复现预期': matches})
            print(f'风险观察 {label} / {"整段" if selected else "光标"}：{before["页数"]} → {after["页数"]} 页', flush=True)
            doc.dispose()


try:
    # 普通表单、表格单元格和已有浮动文字框；不以字号变化作为错误。
    writer, table, frame = writer_form()
    pages(writer, 'baseline')
    before_geometry = geometry(writer, table, frame)
    before_data = table.getDataArray()
    cursor = writer.Text.createTextCursor()
    cursor.gotoStart(False)
    cursor.gotoEndOfParagraph(True)
    writer.CurrentController.select(cursor)
    for name in ['Heading 1', 'Heading 2', 'Text body', 'Standard']:
        dispatch(writer, 'StyleApply', Style=name, FamilyName='ParagraphStyles')
        check('Writer', '标题区样式 ' + name, geometry(writer, table, frame) == before_geometry and table.getDataArray() == before_data)
        check('Writer', name + ' 后仍为一页', pages(writer, name.replace(' ', '-')) == 1)
    for label, selected in [('表格内', table.getCellByName('A2').createTextCursor()), ('文字框内', frame.Text.createTextCursor())]:
        selected.gotoEnd(True)
        writer.CurrentController.select(selected)
        dispatch(writer, 'StyleApply', Style='Heading 1', FamilyName='ParagraphStyles')
        check('Writer', label + '应用标题不增框、不压窄', geometry(writer, table, frame) == before_geometry and table.getDataArray() == before_data)
        dispatch(writer, 'ResetAttributes')
        check('Writer', label + '清除格式保持对象尺寸', geometry(writer, table, frame) == before_geometry)
    writer.CurrentController.select(cursor)
    for command in ['Bold', 'Italic', 'CenterPara', 'RightPara', 'LeftPara', 'JustifyPara', 'IncrementIndent', 'DecrementIndent', 'SpacePara1', 'SpacePara2', 'ResetAttributes']:
        dispatch(writer, command)
        check('Writer', command + ' 不改变对象几何', geometry(writer, table, frame) == before_geometry and table.getDataArray() == before_data)
    # 保存并重新打开三种格式，覆盖旧式 DOC 导入。
    for extension, filter_name in [('odt', 'writer8'), ('docx', 'Office Open XML Text'), ('doc', 'MS Word 97')]:
        dest = args.output / ('mock-form.' + extension)
        writer.storeToURL(uno.systemPathToFileUrl(str(dest.resolve())), props(FilterName=filter_name, Overwrite=True))
        reopened = open_doc(uno.systemPathToFileUrl(str(dest.resolve())))
        t = reopened.TextTables.getByIndex(0)
        f = reopened.DrawPage.getByIndex(0)
        old = geometry(reopened, t, f)
        data_before = t.getDataArray()
        c = reopened.Text.createTextCursor(); c.gotoStart(False); c.gotoEndOfParagraph(True)
        reopened.CurrentController.select(c)
        dispatch(reopened, 'StyleApply', Template='标题 1', Family=uno.Any('short', 2))
        check('Writer', extension + ' 重开后应用标题保留几何及数据', geometry(reopened, t, f) == old and t.getDataArray() == data_before,
              {'操作前几何': old, '操作后几何': geometry(reopened, t, f), '数据不变': t.getDataArray() == data_before})
        check('Writer', extension + ' 重开应用标题仍为一页', pages(reopened, extension + '-heading') == 1)

    observe_narrow_frames()

    calc = open_doc('private:factory/scalc')
    sheet, control = calc.Sheets.getByIndex(0), calc.CurrentController
    cell = sheet.getCellRangeByName
    cell('A1').String = '模拟长文字用于自动换行检查'
    column_width = sheet.Columns.getByIndex(0).Width
    control.select(cell('A1'))
    for command in ['WrapText', 'Bold', 'Italic', 'AlignHorizontalCenter', 'AlignTop', 'AlignBottom', 'ResetAttributes']:
        dispatch(calc, command)
        check('Calc', command + ' 保留文字、列宽与单元格方向', cell('A1').String == '模拟长文字用于自动换行检查' and sheet.Columns.getByIndex(0).Width == column_width and cell('A1').RotateAngle == 0)
    cell('C2').String = '合并标题'; control.select(cell('C2:E2'))
    dispatch(calc, 'ToggleMergeCells')
    check('Calc', '合并居中确实居中且保留文字', cell('C2:E2').IsMerged and cell('C2').HoriJustify.value == 'CENTER' and cell('C2').String == '合并标题', str(cell('C2').HoriJustify))
    dispatch(calc, 'Undo')
    check('Calc', '撤销合并恢复范围与内容', not cell('C2:E2').IsMerged and cell('C2').String == '合并标题')
    cell('G1').Formula = '=H1+1'; cell('H1').Value = 3; cell('H2').Value = 7
    control.select(cell('G1:G2')); dispatch(calc, 'FillDown')
    check('Calc', '向下填充正确移动公式引用', cell('G2').Formula == '=H2+1' and cell('G2').Value == 8)
    cell('J1').Formula = '=J2+2'; cell('J2').Value = 5; cell('K2').Value = 9
    control.select(cell('J1:K1')); dispatch(calc, 'FillRight')
    check('Calc', '向右填充正确移动公式引用', cell('K1').Formula == '=K2+2' and cell('K1').Value == 11)

    draw = open_doc('private:factory/sdraw'); page = draw.DrawPages.getByIndex(0)
    shapes = []
    for x in [2000, 7000]:
        shape = draw.createInstance('com.sun.star.drawing.TextShape')
        page.add(shape)
        shape.Position = uno.createUnoStruct('com.sun.star.awt.Point', x, 3000)
        shape.Size = uno.createUnoStruct('com.sun.star.awt.Size', 4000, 2000)
        shape.TextAutoGrowHeight = False; shape.TextAutoGrowWidth = False
        shape.String = '模拟绘图文字'
        shapes.append(shape)
    def bounds():
        return [(s.Position.X, s.Position.Y, s.Size.Width, s.Size.Height, s.RotateAngle, s.String) for s in shapes]
    original = bounds()
    selection = manager.createInstanceWithContext('com.sun.star.drawing.ShapeCollection', context)
    for s in shapes: selection.add(s)
    draw.CurrentController.select(selection)
    for command in ['Bold', 'Italic', 'Underline', 'CenterPara', 'LeftPara', 'ResetAttributes', 'BringToFront', 'SendToBack']:
        dispatch(draw, command)
        check('Draw', command + ' 保留文字框尺寸位置与文字', bounds() == original)
    dispatch(draw, 'FormatGroup')
    check('Draw', '组合不丢对象', page.Count == 1 and page.getByIndex(0).Count == 2)
    dispatch(draw, 'FormatUngroup')
    check('Draw', '取消组合恢复对象位置尺寸', page.Count == 2 and bounds() == original)
    complete = True
finally:
    report = {'完成': complete, '已安装配置包': args.configured, '普通布局检查': results, '已知风险观察': observations}
    (args.output / '布局排查.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', 'utf8')
    for doc in documents:
        try: doc.dispose()
        except Exception: pass
print(f'检查 {len(results)} 项，失败 {sum(not r["通过"] for r in results)} 项。')
print(f'另观察 {len(observations)} 个窄框场景；风险重现不表示风险已修复。')
sys.exit(any(not r['通过'] for r in results) or any(not r['符合复现预期'] for r in observations))
