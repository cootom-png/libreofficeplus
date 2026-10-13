"""读取专用独立实例中的有效菜单和外观设置；不操作个人文档。"""
import argparse
import json
from pathlib import Path
import xml.etree.ElementTree as ET
import uno

ROOT = Path(__file__).resolve().parents[1]
MODULES = {'swriter': 'text.TextDocument', 'scalc': 'sheet.SpreadsheetDocument',
           'sdraw': 'drawing.DrawingDocument', 'simpress': 'presentation.PresentationDocument'}
NS = '{http://openoffice.org/2001/menu}'


def verify(context, package=ROOT / 'package'):
    manager = context.ServiceManager
    supplier = manager.createInstanceWithContext('com.sun.star.ui.ModuleUIConfigurationManagerSupplier', context)
    records = []

    def native(container):
        result = []
        for i in range(container.Count):
            item = {p.Name: p.Value for p in container.getByIndex(i)}
            child = item.get('ItemDescriptorContainer')
            result.append([item.get('CommandURL', ''), item.get('Label', ''), native(child) if child else []])
        return result

    def expected(element):
        return [[child.get(NS + 'id', ''), child.get(NS + 'label', ''), expected(child.find(NS + 'menupopup'))
                 if child.find(NS + 'menupopup') is not None else []] for child in element]

    for file in json.loads((package / 'profile-files.json').read_text('utf8')):
        module, name = file['Module'], Path(file['Path']).stem
        config = supplier.getUIConfigurationManager('com.sun.star.' + MODULES[module])
        actual = native(config.getSettings('private:resource/popupmenu/' + name, False))
        wanted = expected(ET.parse(package / 'profile' / file['Path']).getroot())
        if actual != wanted:
            raise AssertionError(f'{module}/{name} 有效菜单与配置不一致')
        records.append({'模块': module, '菜单': name, '通过': True, '有效结构': actual})
    provider = manager.createInstanceWithContext('com.sun.star.configuration.ConfigurationProvider', context)
    for setting in json.loads((ROOT / 'config/appearance.json').read_text('utf8')):
        arg = uno.createUnoStruct('com.sun.star.beans.PropertyValue', Name='nodepath', Value=setting['Path'])
        access = provider.createInstanceWithArguments('com.sun.star.configuration.ConfigurationAccess', (arg,))
        actual = access.getPropertyValue(setting['Name'])
        if str(actual).lower() != setting['Value'].lower():
            raise AssertionError(setting['Name'])
        records.append({'设置': setting['Name'], '通过': True, '有效值': actual})
    return records


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pipe', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--package', type=Path, default=ROOT / 'package')
    args = parser.parse_args()
    local = uno.getComponentContext()
    resolver = local.ServiceManager.createInstanceWithContext('com.sun.star.bridge.UnoUrlResolver', local)
    context = resolver.resolve('uno:pipe,name=' + args.pipe + ';urp;StarOffice.ComponentContext')
    records = verify(context, args.package)
    args.output.write_text(json.dumps(records, ensure_ascii=False, indent=2) + '\n', 'utf8')
    print(f'{len(records)} 项有效菜单及外观设置通过。')
