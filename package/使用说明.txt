# LibreOfficePlus

为习惯 WPS 的用户提供 **LibreOffice Writer（文字）、Calc（表格）、Draw（绘图）**的中文功能区、常用操作和可恢复的一键配置包。

当前版本 **v5，WPS 习惯适配版**。以用户提供的 WPS 文字、表格截图为参考，重点调整按钮顺序、分组、常用菜单和键位；Draw 沿用相同的字体、形状、排列与属性栏习惯。它仍使用 LibreOffice 原生界面和文档引擎，**不是 WPS 的逐像素复刻**。

2026-10-12 安装入口修复：解决双击后出现 `'d'`、`'rshell.exe' 不是内部或外部命令` 的问题。遇到此错误，请重新下载并解压完整配置包，再运行新的 `安装.cmd`；原来的首次备份会继续保留。

## 下载与安装

**[下载 main 已合入版本](https://github.com/cootom-png/libreofficeplus/raw/refs/heads/main/dist/LibreOfficePlus-WPS%E7%95%8C%E9%9D%A2%E9%85%8D%E7%BD%AE%E5%8C%85.zip)**。PR 未合入时，此链接仍提供上一版本；查看本 PR 的 `dist/` 文件可获取待合入配置包。

1. 安装 Windows 版 **LibreOffice 26.2.5.2**，构建 ID 必须为 `cd7284b4cbbfeb507e630c1aac019f4157393acb`。
2. 首次使用时，先启动并关闭一次 LibreOffice，让软件生成用户配置。
3. 保存文档，完全退出 LibreOffice。后台仍有进程时安装程序会拒绝修改，不会强制关闭文档。
4. 解压整个 ZIP，进入 `LibreOfficePlus` 文件夹，双击 **`安装.cmd`**。
5. 重新打开所需组件，建议最大化窗口查看“开始”页。

默认安装三个模块，写入当前用户配置，通常不需要管理员权限。请保留解压目录和首次备份。

可在解压目录的 PowerShell 中选择模块，重复安装或追加模块会保留首次备份：

```powershell
.\安装.cmd -Modules Draw
.\安装.cmd -Modules Writer,Calc
```

默认程序路径是 `C:\Program Files\LibreOffice`。自定义安装路径示例：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\configure.ps1 -Modules Writer,Calc,Draw -LibreOfficePath "D:\Apps\LibreOffice"
```

## v5 改进

| 区域 | 本版处理 |
| --- | --- |
| 三个开始页 | 格式刷置左；剪贴板随后；字体、字号和清除格式集中；常用操作按上下两行排列 |
| Writer | 缩进、段落标记并入段落区；上标在下标前；保留样式预览和右侧样式窗格入口 |
| Calc | 换行、合并紧跟对齐区；填充菜单包含上下左右与序列；冻结菜单包含当前位置、首行、首列 |
| Draw | 增加字体字号区；集中形状填充、轮廓、组合、取消组合、旋转、置顶置底和 PDF 导出 |
| 其他选项卡 | 每个配置分组分配独立原生容器，保留上下文页及原生控件；不再将不同分组混排到一串位置 |
| Writer 快捷键 | Ctrl+D 字体、F12 另存为、F4 重复操作；首次键位随备份保存并可恢复 |
| 可选模板 | 文字宋体五号、表格宋体 11 磅、绘图 A4 模板；不自动改为默认模板 |
| 安装与恢复 | 支持按模块安装、追加、恢复；兼容 v3/v4 备份升级及软件保存后的 XML；失败撤回已写入的界面文件 |

选项卡顺序：

- Writer：文件 → 开始 → 插入 → 页面 → 引用 → 审阅 → 视图 → 工具。
- Calc：文件 → 开始 → 插入 → 页面 → 公式 → 数据 → 审阅 → 视图 → 工具。
- Draw：文件 → 开始 → 插入 → 页面 → 审阅 → 视图 → 工具。

图片、绘图、表格等上下文页和原生扩展页继续保留。窄窗口会将分组收进 `»` 溢出区；所有选项卡的控件尺寸、分隔线和换行尚未与 WPS 完全一致。

### 实际窗口预览

以下为独立测试配置中的窗口，未使用个人文档。

![Writer 开始页与样式窗格](docs/writer-home.png)

![Calc 开始页](docs/calc-home.png)

![Draw 开始页、形状与属性栏](docs/draw-home.png)

## 从熟悉的模板开始

双击 `templates/` 中的模板会新建文档：

| 模板 | 内容 |
| --- | --- |
| `WPS习惯文字.ott` | 宋体五号（10.5 磅）、A4、上下边距 2.54 cm、左右边距 3.18 cm |
| `WPS习惯表格.ots` | 宋体 11 磅、Sheet1 空白工作表 |
| `WPS习惯绘图.otg` | A4 纵向空白页面、默认文字宋体 11 磅 |

这些参数来自截图或项目统一设置，不保证复杂文档与 WPS 完全相同。字体须在电脑上存在，否则 LibreOffice 会替代字体。需要长期使用时，可自行在 LibreOffice 模板管理器中将模板设为默认。与 WPS 交换文件时使用“另存为”选择 DOCX/XLSX；先检查版式、公式和图形。Draw 的可编辑原生格式是 ODG。

## 恢复原界面

保存文档并完全退出 LibreOffice，双击 **`恢复原界面.cmd`**。也可仅恢复某个模块：

```powershell
.\恢复原界面.cmd -Modules Draw
```

所选模块的 UI、专属设置及 Writer 键位恢复到首次安装前。原有 UI 文件会还原，新建文件会移除；同一节点下其他属性保留。

**图标主题、功能区图标尺寸及通用命令中文名称属于共享设置**，也可能影响其他 LibreOffice 组件。部分恢复时保留共享设置，直到最后一个本包模块恢复后才一并恢复。按模块安装不表示所有通用名称均能独立隔离。

首次备份位置：

```text
%APPDATA%\LibreOffice\wps-ui-backup.xml
%APPDATA%\LibreOffice\wps-ui-files-backup\
```

升级或重复安装前不要删除备份。安装后自行改过定制 UI 的，请先另存再恢复。备份丢失时无法重建安装前的个人设置。

## 对应关系与验证范围

- [按钮对应表](package/按钮对应表.csv)：命令、逻辑分组、组内顺序和状态；不是像素坐标或全部功能通过记录。
- [按钮差异](docs/按钮差异.md)、[操作习惯](docs/操作习惯.md)：名称、菜单、右键和键位的实际差异。
- [适配计划与进度](docs/适配计划.md)：本版交付、技术限制和下一步验收要求。
- [验收记录](docs/验收记录.md)、[原生操作结果](docs/原生命令验收.json)：每个组件 15 项文档操作、三种模板和三个 Writer 键位，共 51 项。

51 项验证包含 UNO 命令、文档属性和导出结果，**不等于逐个点击 51 个按钮，也不证明全部菜单都正确**。实际窗口检查单独记录。宏、保护、复杂 DOCX/XLSX、所有公式、真实打印及所有显示缩放尚未完整验收。

本包不修改现有文档、默认保存格式或宏安全设置。WPS AI、会员、云服务、素材中心、SmartArt、COM/WPS 加载项、跨文档顶部标签、WPS 专属右键菜单及完整函数分类菜单未实现。部分页面按钮会打开同一个原生页面格式窗口；这不能等同于 WPS 的直接开关。

## 构建与维护

Python 3.10+，仅使用标准库。原生基线已固定在仓库，普通构建不需要安装 LibreOffice。

```powershell
python scripts/build.py
python -m unittest discover -s tests
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/test_installer.ps1
```

PowerShell 测试使用独立目录、合成设置和固定 v4 备份生成器，不访问真实用户配置或结束用户进程。CI 检查结构、可重复构建、生成文件同步及 Windows PowerShell 5.1 安装/恢复；图形与原生行为测试需本地 LibreOffice，方法见验收记录。

| 目录 | 用途 |
| --- | --- |
| `config/` | 非开始页分组、开始页两行入口、已确认命令、名称和键位 |
| `vendor/` | 固定版本原生 UI、来源和 SHA-256 |
| `scripts/` | 构建、模板生成和可选原生操作检查 |
| `package/`、`dist/` | 解压安装文件和 ZIP |
| `tests/`、`docs/` | 自动检查、实际预览、差异与验收记录 |

修改后重新构建并提交 `package/` 和 `dist/`。适配其他构建版本须更新基线、构建限制和实际验收，不能只去掉版本检查。

## 许可与来源

[Mozilla Public License 2.0](LICENSE)。原生 UI 来自 The Document Foundation / LibreOffice contributors 的 LibreOffice 26.2.5.2 Windows 安装文件，上游构建 [`cd7284b4`](https://github.com/LibreOffice/core/tree/cd7284b4cbbfeb507e630c1aac019f4157393acb)，校验值见 [SOURCE.json](vendor/libreoffice/SOURCE.json)。配置包包含修改后的 XML 源文件、许可证和来源说明。WPS 截图仅作习惯参考，未分发 WPS 图标或程序文件。
