"""读取专用 LibreOffice 实例中的有效快捷键；配置读取不等同于模拟按键。"""
import json
from pathlib import Path
import uno

ROOT = Path(__file__).resolve().parents[1]
MODULES = {'com.sun.star.text.TextDocument': 'Writer',
           'com.sun.star.sheet.SpreadsheetDocument': 'Calc',
           'com.sun.star.drawing.DrawingDocument': 'Draw',
           'com.sun.star.presentation.PresentationDocument': 'Impress'}


def key_event(key):
    parts = key.split('_')
    name = 'NUM' + parts[0] if parts[0].isdigit() else parts[0]
    modifiers = sum({'SHIFT': 1, 'MOD1': 2, 'MOD2': 4}[part] for part in parts[1:])
    return uno.createUnoStruct('com.sun.star.awt.KeyEvent',
                              KeyCode=uno.getConstantByName('com.sun.star.awt.Key.' + name),
                              Modifiers=modifiers)


def verify(context):
    manager = context.ServiceManager
    supplier = manager.createInstanceWithContext('com.sun.star.ui.ModuleUIConfigurationManagerSupplier', context)
    global_keys = manager.createInstanceWithContext('com.sun.star.ui.GlobalAcceleratorConfiguration', context)
    results = []

    def check(module, key, command, mode):
        shortcuts = supplier.getUIConfigurationManager(module).getShortCutManager()
        event = key_event(key)
        try:
            actual = shortcuts.getCommandByKeyEvent(event)
        except Exception:
            try:
                actual = global_keys.getCommandByKeyEvent(event)
            except Exception as error:
                raise AssertionError(f'{module}/{key}: 未找到有效快捷键') from error
        if actual != command:
            raise AssertionError(f'{module}/{key}: {actual} != {command}')
        results.append({'模块': MODULES[module], '操作': '快捷键 ' + key,
                        '有效命令': actual, '方式': mode, '通过': True})

    for entry in json.loads((ROOT / 'config/shortcuts.json').read_text('utf8')):
        module, key = entry['Path'].split('/')[-2:]
        check(module, key, entry['Value'], '配置对齐')
    # 已经相同的原生键位无需重复写入；同时防止跨模块覆盖。
    for module in MODULES:
        for key, command in [('C_MOD1', 'Copy'), ('X_MOD1', 'Cut'), ('V_MOD1', 'Paste'),
                             ('S_MOD1', 'Save'), ('Z_MOD1', 'Undo'), ('Y_MOD1', 'Redo')]:
            check(module, key, '.uno:' + command, '保留原生')
    for key, command in [('D_MOD1', 'FillDown'), ('1_MOD1', 'FormatCellDialog'),
                         ('L_SHIFT_MOD1', 'DataFilterAutoFilter'), ('F4', 'ToggleRelative'),
                         ('SEMICOLON_MOD1', 'InsertCurrentDate'), ('SEMICOLON_SHIFT_MOD1', 'InsertCurrentTime')]:
        check('com.sun.star.sheet.SpreadsheetDocument', key, '.uno:' + command, '保留原生')
    check('com.sun.star.drawing.DrawingDocument', 'F4', '.uno:TransformDialog', '保留原生')
    for key, command in [('F5', 'Presentation'), ('F5_SHIFT', 'PresentationCurrentSlide')]:
        check('com.sun.star.presentation.PresentationDocument', key, '.uno:' + command, '保留原生')
    return results
