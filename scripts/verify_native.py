"""使用独立无界面 LibreOffice 实例验证原生命令和可选模板，不访问个人文档。"""
import argparse
import json
import sys
import time
from pathlib import Path
import uno
from com.sun.star.lang import DisposedException
from com.sun.star.uno import RuntimeException


def main():
    sys.stdout.reconfigure(encoding='utf8')
    parser=argparse.ArgumentParser()
    parser.add_argument('--pipe',required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--configured',action='store_true',help='验证已安装本包的独立配置中的 Writer 快捷键')
    args=parser.parse_args()
    args.output.mkdir(parents=True,exist_ok=True)
    local=uno.getComponentContext()
    resolver=local.ServiceManager.createInstanceWithContext('com.sun.star.bridge.UnoUrlResolver',local)
    for attempt in range(30):
        try:
            context=resolver.resolve(f'uno:pipe,name={args.pipe};urp;StarOffice.ComponentContext')
            break
        except Exception:
            if attempt==29: raise
            time.sleep(0.5)
    manager=context.ServiceManager
    desktop=manager.createInstanceWithContext('com.sun.star.frame.Desktop',context)
    helper=manager.createInstanceWithContext('com.sun.star.frame.DispatchHelper',context)
    results=[]
    docs=[]
    def properties(**values):
        return tuple(uno.createUnoStruct('com.sun.star.beans.PropertyValue',Name=k,Value=v) for k,v in values.items())
    def open_doc(url):
        doc=desktop.loadComponentFromURL(url,'_blank',0,properties(Hidden=True,AsTemplate=True))
        docs.append(doc)
        return doc
    def check(module,name,condition):
        results.append({'模块':module,'操作':name,'通过':bool(condition)})
        if not condition: raise AssertionError(f'{module}: {name}')
    def dispatch(doc,command):
        helper.executeDispatch(doc.CurrentController.Frame,'.uno:'+command,'',0,())
    def export(doc,module,filter_name):
        dest=args.output/(module+'.pdf')
        doc.storeToURL(uno.systemPathToFileUrl(str(dest.resolve())),properties(FilterName=filter_name,Overwrite=True))
        check(module,'PDF 导出',dest.read_bytes().startswith(b'%PDF-'))
    try:
        writer=open_doc('private:factory/swriter')
        if args.configured:
            supplier=manager.createInstanceWithContext('com.sun.star.ui.ModuleUIConfigurationManagerSupplier',context)
            shortcuts=supplier.getUIConfigurationManager('com.sun.star.text.TextDocument').getShortCutManager()
            for name,key,mods,command in [('Ctrl+D','D',2,'FontDialog'),('F12','F12',0,'SaveAs'),('F4','F4',0,'Repeat')]:
                event=uno.createUnoStruct('com.sun.star.awt.KeyEvent',KeyCode=uno.getConstantByName('com.sun.star.awt.Key.'+key),Modifiers=mods)
                check('Writer','快捷键 '+name,shortcuts.getCommandByKeyEvent(event)=='.uno:'+command)
        writer.Text.String='WPS habit test'
        cursor=writer.Text.createTextCursor(); cursor.gotoEnd(True); writer.CurrentController.select(cursor)
        check('Writer','输入文字',writer.Text.String=='WPS habit test')
        dispatch(writer,'Bold'); check('Writer','加粗',cursor.CharWeight>100)
        dispatch(writer,'Italic'); check('Writer','斜体',str(cursor.CharPosture.value)=='ITALIC')
        dispatch(writer,'Underline'); check('Writer','下划线',cursor.CharUnderline!=0)
        dispatch(writer,'CenterPara'); check('Writer','居中',cursor.ParaAdjust==3)
        dispatch(writer,'RightPara'); check('Writer','右对齐',cursor.ParaAdjust==1)
        dispatch(writer,'LeftPara'); check('Writer','左对齐',cursor.ParaAdjust==0)
        dispatch(writer,'JustifyPara'); check('Writer','两端对齐',cursor.ParaAdjust==2)
        cursor.CharFontName='宋体'; check('Writer','字体设置',cursor.CharFontName=='宋体')
        cursor.CharHeight=10.5; check('Writer','五号字号',cursor.CharHeight==10.5)
        dispatch(writer,'ResetAttributes'); check('Writer','清除直接格式',cursor.CharWeight==100)
        writer.CurrentController.ViewCursor.gotoEnd(False)
        dispatch(writer,'InsertPagebreak'); check('Writer','插入分页符',writer.CurrentController.ViewCursor.Page==2)
        dispatch(writer,'Undo'); check('Writer','撤销分页',writer.CurrentController.ViewCursor.Page==1)
        dispatch(writer,'Redo'); check('Writer','重做分页',writer.CurrentController.ViewCursor.Page==2)
        export(writer,'Writer','writer_pdf_Export')

        calc=open_doc('private:factory/scalc'); sheet=calc.Sheets.getByIndex(0); control=calc.CurrentController
        def cell(ref): return sheet.getCellRangeByName(ref)
        def fill(ref,source,value,command,target):
            cell(source).Value=value; control.select(cell(ref)); dispatch(calc,command)
            check('Calc',command,cell(target).Value==value)
        fill('A1:A3','A1',7,'FillDown','A3')
        fill('A1:C1','A1',8,'FillRight','C1')
        fill('A5:A7','A7',9,'FillUp','A5')
        fill('A9:C9','C9',10,'FillLeft','A9')
        control.select(cell('E1:F1')); dispatch(calc,'ToggleMergeCells'); check('Calc','合并居中',cell('E1:F1').IsMerged)
        dispatch(calc,'ToggleMergeCells'); check('Calc','取消合并',not cell('E1:F1').IsMerged)
        control.select(cell('A1')); dispatch(calc,'WrapText'); check('Calc','自动换行',cell('A1').IsTextWrapped)
        dispatch(calc,'NumberFormatPercent'); check('Calc','百分比格式',calc.NumberFormats.getByKey(cell('A1').NumberFormat).Type & uno.getConstantByName('com.sun.star.util.NumberFormat.PERCENT'))
        # 冻结依赖可见视图尺寸，另外通过实际图形窗口检查。
        dispatch(calc,'Italic'); check('Calc','斜体',str(cell('A1').CharPosture.value)=='ITALIC')
        dispatch(calc,'Underline'); check('Calc','下划线',cell('A1').CharUnderline!=0)
        dispatch(calc,'AlignHorizontalCenter'); check('Calc','水平居中',str(cell('A1').HoriJustify.value)=='CENTER')
        cell('A11').Formula='=SUM(A1:A3)'; check('Calc','SUM 公式',cell('A11').Value==22)
        control.select(cell('A1')); dispatch(calc,'Bold'); check('Calc','加粗',cell('A1').CharWeight>100)
        dispatch(calc,'Undo'); check('Calc','撤销加粗',cell('A1').CharWeight==100)
        export(calc,'Calc','calc_pdf_Export')

        draw=open_doc('private:factory/sdraw'); page=draw.DrawPages.getByIndex(0)
        def shape(kind,x):
            obj=draw.createInstance('com.sun.star.drawing.'+kind)
            obj.Position=uno.createUnoStruct('com.sun.star.awt.Point',x,2000)
            obj.Size=uno.createUnoStruct('com.sun.star.awt.Size',2000,1200)
            page.add(obj); return obj
        rect=shape('RectangleShape',2000); check('Draw','绘制矩形',page.Count==1)
        ellipse=shape('EllipseShape',6000); check('Draw','绘制椭圆',page.Count==2)
        text=shape('TextShape',10000); text.String='WPS habit'; check('Draw','文本框',text.String=='WPS habit')
        rect.FillColor=0x3366CC; check('Draw','形状填充',rect.FillColor==0x3366CC)
        rect.LineColor=0xCC3333; check('Draw','形状轮廓',rect.LineColor==0xCC3333)
        rect.LineWidth=50; check('Draw','轮廓宽度',rect.LineWidth==50)
        check('Draw','位置和大小',rect.Position.X==2000 and rect.Size.Width==2000)
        rect.RotateAngle=4500; check('Draw','旋转角度',rect.RotateAngle==4500)
        selected=manager.createInstanceWithContext('com.sun.star.drawing.ShapeCollection',context)
        selected.add(rect); selected.add(ellipse); draw.CurrentController.select(selected)
        dispatch(draw,'FormatGroup'); check('Draw','组合',page.Count==2)
        dispatch(draw,'FormatUngroup'); check('Draw','取消组合',page.Count==3)
        draw.CurrentController.select(rect); dispatch(draw,'BringToFront'); check('Draw','置于顶层',rect.ZOrder==2)
        dispatch(draw,'SendToBack'); check('Draw','置于底层',rect.ZOrder==0)
        draw.DrawPages.insertNewByIndex(1); check('Draw','新建页面',draw.DrawPages.Count==2)
        draw.DrawPages.remove(draw.DrawPages.getByIndex(1)); check('Draw','删除页面',draw.DrawPages.Count==1)
        export(draw,'Draw','draw_pdf_Export')

        templates=Path(__file__).resolve().parents[1]/'package/templates'
        for name,extension,module in [('文字','ott','Writer'),('表格','ots','Calc'),('绘图','otg','Draw')]:
            doc=open_doc(uno.systemPathToFileUrl(str(templates/f'WPS习惯{name}.{extension}')))
            if module=='Writer': valid=doc.Text.createTextCursor().CharHeight==10.5
            elif module=='Calc': valid=doc.Sheets.getByIndex(0).getCellRangeByName('A1').CharHeight==11
            else:
                text=doc.createInstance('com.sun.star.drawing.TextShape')
                doc.DrawPages.getByIndex(0).add(text); text.String='template font'
                valid=doc.DrawPages.getByIndex(0).Width==21000 and text.CharHeight==11 and text.CharFontNameAsian=='宋体'
            check(module,'可选模板加载',valid)
    finally:
        (args.output/'原生命令验收.json').write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n','utf8')
        for doc in docs:
            try: doc.close(True)
            except DisposedException: pass  # 最后一个隐藏文档关闭后，独立实例可能已退出。
            except RuntimeException as error:
                if 'illegal object given!' not in str(error): raise
        try: desktop.terminate()
        except DisposedException: pass
    print(f'通过 {len(results)} 项原生命令、文档操作和模板检查。')


if __name__=='__main__': main()
