"""构建可选的空白 ODF 模板；不修改用户的默认模板。"""
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED, ZIP_STORED

NS = ('xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" '
      'xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" '
      'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" '
      'xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" '
      'xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" '
      'xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" '
      'xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0"')
FONT = '<office:font-face-decls><style:font-face style:name="宋体" svg:font-family="宋体"/></office:font-face-decls>'


def build_templates(package):
    folder=package/'templates'
    folder.mkdir(exist_ok=True)
    for name,kind,extension,size in [('文字','text','ott','10.5'),('表格','spreadsheet','ots','11'),('绘图','graphics','otg','11')]:
        mime=f'application/vnd.oasis.opendocument.{kind}-template'
        default=(f'<style:default-style style:family="paragraph"><style:text-properties style:font-name="宋体" '
                 f'style:font-name-asian="宋体" fo:font-size="{size}pt" style:font-size-asian="{size}pt"/></style:default-style>')
        if kind=='spreadsheet':
            default+=f'<style:default-style style:family="table-cell"><style:text-properties style:font-name="宋体" style:font-name-asian="宋体" fo:font-size="{size}pt" style:font-size-asian="{size}pt"/></style:default-style>'
        margin='fo:margin-top="2.54cm" fo:margin-bottom="2.54cm" fo:margin-left="3.18cm" fo:margin-right="3.18cm"' if kind=='text' else 'fo:margin="1.9cm"'
        styles=(f'<office:document-styles {NS} office:version="1.3">{FONT}<office:styles>{default}</office:styles>'
                f'<office:automatic-styles><style:page-layout style:name="pm1"><style:page-layout-properties fo:page-width="21cm" fo:page-height="29.7cm" style:print-orientation="portrait" {margin}/></style:page-layout></office:automatic-styles>'
                '<office:master-styles><style:master-page style:name="Standard" style:page-layout-name="pm1"/></office:master-styles></office:document-styles>')
        bodies={'text':'<office:text><text:p/></office:text>',
                'spreadsheet':'<office:spreadsheet><table:table table:name="Sheet1"><table:table-column/><table:table-row><table:table-cell><text:p/></table:table-cell></table:table-row></table:table></office:spreadsheet>',
                'graphics':'<office:drawing><draw:page draw:name="页面 1" draw:master-page-name="Standard"/></office:drawing>'}
        content=f'<office:document-content {NS} office:version="1.3">{FONT}<office:body>{bodies[kind]}</office:body></office:document-content>'
        manifest=(f'<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.3">'
                  f'<manifest:file-entry manifest:full-path="/" manifest:media-type="{mime}"/>'
                  '<manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>'
                  '<manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/></manifest:manifest>')
        with ZipFile(folder/f'WPS习惯{name}.{extension}','w') as archive:
            for path,text in [('mimetype',mime),('content.xml',content),('styles.xml',styles),('META-INF/manifest.xml',manifest)]:
                info=ZipInfo(path,(2026,10,10,0,0,0))
                info.compress_type=ZIP_STORED if path=='mimetype' else ZIP_DEFLATED
                info.external_attr=0o644<<16
                archive.writestr(info,text.encode('utf8'))
