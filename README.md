# LibreOfficePlus

面向习惯 WPS 的用户，为 **LibreOffice Writer（文字）和 Calc（表格）**提供中文界面配置与可恢复的一键安装包。

当前版本 **v4，部分位置适配版**。以 WPS 截图中的选项卡顺序和常用操作为参考，使用 LibreOffice 原生命令。按钮分组、换行、尺寸、部分名称和弹窗仍有差异，**尚未完成逐项、逐像素复刻**。

## 下载和安装

**[下载一键配置包](https://github.com/cootom-png/libreofficeplus/raw/refs/heads/main/dist/LibreOfficePlus-WPS%E7%95%8C%E9%9D%A2%E9%85%8D%E7%BD%AE%E5%8C%85.zip)**

1. 确认已安装 Windows 版 **LibreOffice 26.2.5.2**。本包校验构建 ID `cd7284b4cbbfeb507e630c1aac019f4157393acb`，其他构建会拒绝安装。
2. 首次使用 LibreOffice 时，先启动并关闭一次，让软件生成用户配置。
3. 保存文档，完全退出所有 LibreOffice 窗口；后台还有进程时，安装程序会提示退出。
4. 解压整个 ZIP，进入 `LibreOfficePlus` 文件夹，双击 **`安装.cmd`**。
5. 重新打开 Writer 或 Calc，在“开始”页检查布局。

安装仅写入当前用户配置，通常不需要管理员权限。请保留解压目录，恢复时使用其中的入口。

默认程序路径为 `C:\Program Files\LibreOffice`。如果安装在其他位置，可在 PowerShell 中指定路径：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\设置界面.ps1 -LibreOfficePath "D:\Apps\LibreOffice"
```

## v4 优化内容

| 位置 | 本版变化 |
| --- | --- |
| 文字和表格的开始页 | 格式刷成为最左侧独立大按钮；粘贴、剪切和复制紧随其后；清除格式移到字体区 |
| 文字开始页 | 保留字体、段落和样式预览；增加样式窗格、查找替换、批注和选择全部入口 |
| 表格开始页 | 换行和合并移到对齐区后；数字格式随后；新增填充、求和、排序、筛选、冻结窗格和查找入口 |
| 常用名称 | 将“克隆”等名称调整为“格式刷”等熟悉叫法；同时保存菜单、提示文字的原值，支持恢复 |
| 文字选项卡 | 文件 → 开始 → 插入 → 页面 → 引用 → 审阅 → 视图 → 工具 |
| 表格选项卡 | 文件 → 开始 → 插入 → 页面 → 公式 → 数据 → 审阅 → 视图 → 工具 |
| 上下文功能 | 保留原生图片、绘图、表格等上下文页；扩展管理从“工具”进入 |
| 安装与恢复 | 兼容 v3 备份升级；重复安装保留首次配置；检查运行中进程和软件构建版本 |

其他选项卡沿用已验证可显示的原生按钮容器，按参考顺序安排入口。它们仍受原生分组和换行规则影响。窗口较窄时，部分分组进入 `»` 溢出区，建议最大化窗口使用。

已清理开始页中被替代的重复入口；其他选项卡保留原生分组和部分分隔线，以维持正常显示。

常用名称设置包含 80 项名称属性，涉及 18 个命令及其不同模块定义；不是新增 80 个功能。通用命令的名称调整也可能出现在 LibreOffice 的其他组件或菜单中。

### 实际窗口预览

文字开始页与样式窗格（空白测试文档）：

![文字开始页与样式窗格](docs/writer-home.png)

表格开始页（空白测试工作表）：

![表格开始页](docs/calc-home.png)

## 恢复原界面

保存文档并完全退出 LibreOffice，双击 **`恢复原界面.cmd`**。

恢复范围包括本包修改的设置、中文按钮名称及 Writer/Calc 的 `notebookbar.ui` 文件。原先存在的文件会恢复，新建的文件会移除；同一配置节点下其他属性会保留。

首次备份位于：

```text
%APPDATA%\LibreOffice\wps-ui-backup.xml
%APPDATA%\LibreOffice\wps-ui-files-backup\
```

升级或重复安装前不要删除这些备份。安装后若自行修改过定制 UI，请先另存文件再恢复。配置备份丢失时，本包无法重建安装前的个人设置。

## 功能边界

- 本包定制界面，不改变 LibreOffice 的文档排版、公式计算或格式兼容引擎。
- 默认字体、字号、缩放、保存格式、现有文档和宏安全设置均不修改。
- 页边距、打印网格线、打印缩放等部分入口会打开原生设置窗口，不能等同于 WPS 的直接开关。
- “数据区域”是 Calc 的数据库区域；“单元格格式（保护）”打开格式窗口，不能当作锁定切换开关。
- WPS AI、会员、云服务、素材中心、SmartArt、COM/WPS 加载项及跨文档顶端标签等未实现。
- WPS 式函数分类菜单、所有选项卡的精确两行排布仍待后续开发。
- 未逐个执行全部命令。具体通过的检查及未验证范围见 [验收记录](docs/验收记录.md)。

详细对应关系见 [按钮对应表](package/按钮对应表.csv) 和 [按钮差异说明](docs/按钮差异.md)。

## 项目结构

```text
config/       选项卡、命令和中文名称映射
vendor/       固定构建版本的原生 UI 基线及来源、校验值
scripts/      Python 构建脚本（仅标准库）
package/      可直接解压安装的文件、生成后的 UI 与对应表
dist/         一键配置 ZIP
tests/        UI 结构、可重复构建和隔离安装/恢复检查
docs/         差异和验收记录
```

仓库不包含个人 LibreOffice 配置、业务文档或本机调试日志。

## 构建与验证

要求 Python 3.10+。构建不需要在机器上安装 LibreOffice：原生基线已固定保存在仓库内。

```powershell
python scripts/build.py
python -m unittest discover -s tests
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/test_installer.ps1
```

最后一项需在 Windows 上执行。测试使用独立目录和合成配置，模拟软件版本与进程状态，不修改真实用户配置、不结束用户进程。

修改 `config/layout.json` 调整非开始页的命令顺序；修改 `config/labels.json` 调整常用中文名称；开始页的原生控件移动在 `scripts/build.py` 中。重新构建后提交 `package/` 与 `dist/` 的对应结果。

CI 执行结构检查、可重复构建和 Windows PowerShell 5.1 的隔离安装/恢复测试。**CI 不证明图形窗口正常，也不证明所有按钮功能正确**；更改布局后还需要使用独立 LibreOffice 用户配置进行实际窗口检查。

适配其他 LibreOffice 版本时，必须更新原生基线、构建校验和验收记录，不能只移除安装版本限制。

## 许可与来源

项目使用 [Mozilla Public License 2.0](LICENSE)。原生 UI 基于 The Document Foundation / LibreOffice contributors 的 LibreOffice 26.2.5.2 Windows 安装文件；对应上游构建为 [`cd7284b4`](https://github.com/LibreOffice/core/tree/cd7284b4cbbfeb507e630c1aac019f4157393acb)。

基线来源和校验值见 [SOURCE.json](vendor/libreoffice/SOURCE.json)。配置包内提供修改后的 XML 源文件、许可证及来源说明。WPS 截图仅用于布局参考，项目未分发 WPS 图标或程序文件。
