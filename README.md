# PaperDesk 作业排版

**使用与开发手册 · 当前实现版本 0.2.0 · 文档更新 2026-09-12**

日常使用先读下面的启动、图文操作和保存说明；学习源码或准备继续开发，跳到[开发与学习手册](#developer-guide)。实际测试和未完成项见 [STATUS.md](STATUS.md)，范围与阶段计划见 [PLAN.md](PLAN.md)。

面向个人 Mac 的本地图文作业编辑器：固定 A4 多页，摆文字和图片，然后导出 PDF。使用 Swift + AppKit、PDFKit 和系统 ImageIO，不需要 Python、Node、Java 或在线服务。当前源码以 macOS 13 及以上为目标，构建脚本在 Apple 芯片 Mac 上生成 arm64 程序。

## 启动

从 GitHub 克隆项目后启动（私有仓库需要先登录有访问权限的 GitHub 账号）：

```bash
git clone https://github.com/gruTGU/PaperDesk.git
cd PaperDesk
./run.sh
```

如果已经下载并解压交付包，直接在终端进入其中的 `PaperDesk` 目录，执行 `./run.sh`，无需再次克隆。仓库中的 `build/` 不纳入版本控制；已有 Mac arm64 App 和完整源码可从 [v0.2.0 下载页](https://github.com/gruTGU/PaperDesk/releases/tag/v0.2.0) 获取 `PaperDesk-mac-arm64.zip`，解压后 App 位于 `PaperDesk/build/PaperDesk.app`。

首次启动会编译、生成并打开 `build/PaperDesk.app`；以后源码有改动时自动重编译。也可以在 Finder 中双击该 `.app`。构建使用本机已有的 Xcode Command Line Tools，不下载依赖；复制工程到其他目录后，从新位置运行 `./run.sh` 即可。单独重建执行 `./build.sh`。

应用采用本机临时签名，便于自己使用，尚未做对外分发所需的开发者签名和 Apple 公证。

当前版本为 0.2.0：新增上下左右独立页边距、画布左右平移、多文档标签与独立窗口、顶部“另存为”和存储空间管理。沿用 0.1.1 的浅色面板和深色文字，不改变系统外观设置。

## 建议的使用流程

1. 新建作业，在 A4 页上双击空白处建立文字框，双击已有文字框编辑。文字是可编辑富文本。
2. 导入图片，或把 Finder 中的图片拖进纸张；单击选中后拖动位置，拖右下角手柄改变大小。图片默认保持比例，按住 Shift 可以改变比例。
3. 使用缩放看细节，调整两张纸在操作台上的间距。这两个设置只改变屏幕显示，A4 仍为 210 × 297 mm，PDF 中没有操作台的页间空隙。
4. 图片可以矩形裁剪、排成网格拼图，并可调整前后层次；Shift 单击可以多选。拖到另一张纸可跨页移动。
5. 把 `.paperdesk` 工程保存为继续编辑的原件；完成后再导出 PDF 交作业。

右侧“A4 页边距 · mm”分别设置纸张内部的上、下、左、右留白。它与两张纸之间的“页间距”是两个设置。新文字框、拼图及基础 DOCX 分页遵循新的内容区域，已有图文保留原位置；边距参考线不导出到 PDF。边距须为非负数，并至少保留 10 × 10 mm 的内容区域。

缩放时尽量保留当前视图中心对应的纸张位置。任何缩放比例下，都可用底部横向滚动条、触控板横向滚动或 Shift + 滚轮左右查看页面。勾选工具栏“平移”后可直接拖动画布；也可先单击画布取得焦点，再按住空格拖动。文字编辑或输入框内的空格仍用于输入文字。平移只移动视图，不移动纸上的对象。

文本框出现红色边框表示内容装不下。加高文字框、减小字号，或手动把一部分文字放到新页。首版不会把自己新建的长文自动续排到下一页；PDF 导出会阻止文字溢出造成的静默截断。

## 多文档与另存为

顶部“新标签”或 ⌘T / ⌘N 会在当前窗口新建一份独立文档；打开对话框可以同时选择多个工程、DOCX 或 Markdown 文件，分别放入标签。单击标签或用 Control + Tab / Control + Shift + Tab 切换。每份文档都有独立的内容、撤销历史、保存状态和恢复备份。

需要并排查看时，用 ⇧⌘N 新建独立窗口，或在“窗口”菜单选择“将当前标签移到独立窗口”。⌘W 关闭当前标签；有未保存修改时会询问是否保存。

顶部“另存为”或 ⇧⌘S 打开工程另存对话框，默认建议“原名-副本.paperdesk”。选择不同文件名后，当前标签继续编辑新文件，原工程文件保留不变。若选择已有文件，仍会按保存对话框确认覆盖；正在被其他标签使用的工程路径不能覆盖。

## 图片转存与压缩

PNG、JPEG/JPG 和 HEIF/HEIC 使用 macOS 的系统解码器与编码器。PNG 保留透明背景，JPEG 和 HEIC 用白色填充透明处。图片裁剪保存在工程的裁剪参数里，原始图片保留在工程中；单图导出使用裁剪后的画面。

目标大小表示“文件不超过这个上限”，并不保证恰好等于输入值。JPEG/HEIC 会先降低编码质量，仍过大时缩小像素尺寸；PNG 通过缩小像素尺寸达到上限。应用按实际编码后的字节数检查，显示实际文件大小与输出尺寸；目标小到无法满足时会明确报错。越小的上限通常意味着更少的细节，文字截图建议优先使用 PNG 并留足容量。

HEIC 需要当前 Mac 可用的系统编码服务。开发工具的受限执行环境可能阻止该服务；程序会报告编码失败，不会把其他格式伪装成 HEIC。请以本机运行 `./test.sh` 的实际结果为准。

大小输入使用十进制 KB（1 KB = 1000 字节），输入 0 表示不设上限。图片另存和压缩不修改工程里的原图。

## 工程、PDF、Word 与 Markdown

| 格式 | 用途与保留内容 |
| --- | --- |
| `.paperdesk` | 继续编辑的完整原件；保存多页、对象坐标、富文本、原始图片、裁剪、四边页边距和显示设置。旧工程会采用原来的 15 mm 页边距。 |
| PDF | 交作业和打印；保持 A4、图片位置和版面，文字可选择。只支持导出，不做 PDF 转回 Word、Markdown 或 OCR。 |
| DOCX | 基础内容交换；可导入、编辑和导出文字、段落及图片。自由摆放会按阅读顺序变成文档内容，不能保证与纸张画布完全同版。 |
| Markdown | 基础文字与图片交换；图片写入旁边的资源文件夹。字体、字号、分页和自由坐标不属于 Markdown 的完整表达范围。 |

DOCX 和 Markdown 都可以导入后再导出 PDF，也可以通过导入、再导出的流程互转。首版以普通段落和图片为范围，不承诺复杂表格、公式、页眉页脚、脚注、批注、修订、复杂浮动环绕、列表编号和特殊嵌入对象的完整保真。格式交换前建议保留来源文件；对最终排版要求严格时以 PDF 为交付文件。

DOCX 导出写入四个独立页边距，图片按内容区域缩放；导入支持正文末尾的单节页边距，多节文档的不同页面设置不会完整保留。Word 边距精度为 1 twip（1/20 点），换算可能有小于 0.05 点的差异。Markdown 不保存页边距。

PDF 保留可选择的文本层。macOS 的部分中文字体会把同形文字映射成兼容部首，因此从 PDF 复制文本时可能出现不同的 Unicode 字符；显示与打印不受影响，需要继续编辑文字时请使用工程、DOCX 或 Markdown 原件。

Markdown 图片使用本地相对路径。复制或分享导出的 Markdown 时，要连同旁边的资源文件夹一起复制，并保持二者相对位置。导入不会下载网络图片。

## 操作提示

| 操作 | 快捷方式 |
| --- | --- |
| 新建文档标签 | ⌘T 或 ⌘N |
| 新建独立窗口 | ⇧⌘N |
| 打开 / 保存工程 / 另存为 | ⌘O / ⌘S / ⇧⌘S |
| 关闭当前标签 | ⌘W |
| 下一个 / 上一个标签 | Control + Tab / Control + Shift + Tab |
| 左右移动视图 | 横向滚动条、触控板横向滚动或 Shift + 滚轮 |
| 拖动平移视图 | 勾选“平移”，或画布获得焦点后按住空格拖动 |
| 撤销 / 重做 | ⌘Z / ⇧⌘Z |
| 进入文字编辑 | 双击文字框，或选中文字框后按 Return |
| 结束文字编辑 | Esc，或单击画布其他位置 |
| 删除选中的对象 | Delete；编辑文字时按 Delete 只删除文字 |
| 多选对象 | Shift 单击 |
| 微调位置 | 方向键；Shift + 方向键每次移动 10 点 |

保存工程与导出是不同操作。自动恢复用于找回意外退出前的内容，不能替代自己保存 `.paperdesk` 文件。

恢复文件按文档分别保存在 `~/Library/Application Support/PaperDesk/Recovery/*.paperdesk`。旧版保存在 `~/Library/Application Support/PaperDesk/Recovery*.paperdesk` 的备份仍会被读取。启动时可“恢复全部”，分别打开为标签；选择“暂不恢复”会保留备份，新文档使用自己的备份文件。

## 存储空间与清理

点击窗口底部“存储空间”，或“文件 → 存储空间与缓存…”，打开独立管理面板。列表显示全部打开文档的图片预览内存估算、PaperDesk 磁盘缓存及恢复备份的名称、位置和占用大小，可刷新查看。

“清理图片预览”释放解码后的内存图片，再次显示时按需生成；“清理磁盘缓存”清理 `~/Library/Caches/PaperDesk/` 内的应用缓存。它们不删除工程内嵌的原图，也不扫描或清理其他应用、下载目录或源码的编译缓存。

恢复备份单独管理：选择不再需要的备份，再按“删除所选恢复备份…”，确认后删除。正在被打开文档使用的备份受到保护；已保存的普通工程文件不在清理范围内。备份可能包含尚未另存的内容，删除前先确认是否需要恢复。

## 验证与继续开发

```bash
./test.sh
```

自检覆盖工程保存/重开、旧工程兼容、四边页边距校验与失败保存保护；PNG/JPEG/HEIC 编解码、EXIF 方向、裁剪与实际压缩大小上限；两页 A4 PDF、文本层和显示设置不影响输出；DOCX 页边距与中英文图片往返、Markdown 往返。测试样本默认只写到临时目录，结束时清理；失败会输出 `FAIL` 并返回非零退出码。可执行程序保存在 `build/`，编译缓存默认保存在 `work/module-cache/`。

`./test-ui.sh` 会在程序内部验证深浅色环境的文字对比度、编辑、字号、删除与撤销重做、页面操作、页边距、平移及多文档生命周期，并把界面离屏渲染到 `work/ui-test/interface.png`。它不会操作你的桌面，也不能代替实际鼠标、键盘和输入法验收。

`./test-storage.sh` 在临时测试目录验证缓存清理、备份枚举和使用中备份保护，不清理你的实际存储。0.2.0 的核心、内部界面和存储自检记录汇总于 `FEATURES-VALIDATION.txt`。

自检不等于真实 Microsoft Word 版式验收，也不能替代拖动、文本输入等 GUI 操作检查。当前实际验证记录见 `STATUS.md`；整体范围和分阶段计划见 `PLAN.md`。额度用尽或换对话后，先让开发助手读这三个文件，再继续处理未完成项。

若当前测试环境没有可用 HEIC 编码服务，可执行 `PAPERDESK_SKIP_HEIC=1 ./test.sh` 验证其他功能。日志会明确显示 HEIC 被跳过，不代表该功能通过。

源码组织：`Models.swift` 负责工程模型与校验；`CanvasView.swift` / `EditorController.swift` 负责画布和界面；`WorkspaceController.swift` 管理文档标签与窗口；`StorageManager.swift` 管理缓存与恢复备份；`ImageTools.swift` 负责图片；`PDFExporter.swift` 负责 A4 输出；`Conversion.swift` 负责 DOCX / Markdown 内容交换。

<a id="developer-guide"></a>

# 开发与学习手册


开发手册目录：

- [1. 技术栈与开发环境](#dev-1)
- [2. 目录地图和阅读顺序](#dev-2)
- [3. 启动、事件循环和对象关系](#dev-3)
- [4. 工程文件的数据结构](#dev-4)
- [5. A4、单位和三套坐标](#dev-5)
- [6. 绘制、选择、拖动与缩放](#dev-6)
- [7. 富文本编辑：没有自己重写输入法和排版器](#dev-7)
- [8. 图片、裁剪、拼图与指定大小压缩](#dev-8)
- [9. PDF、DOCX、Markdown 的实现路径](#dev-9)
- [10. 保存、撤销、恢复与多窗口](#dev-10)
- [11. 缓存、内存与线程边界](#dev-11)
- [12. 从 Swift 源码到可双击的 .app](#dev-12)
- [13. 日常开发、调试与交付流程](#dev-13)
- [14. 测试覆盖和应如何扩展](#dev-14)
- [15. 常见修改应从哪里入手](#dev-15)
- [16. 后续完善建议与验收条件](#dev-16)
- [17. 排错与交接清单](#dev-17)
- [18. 用这个 App 理解操作系统](#dev-18)
- [19. 配合源码学习的官方资料](#dev-19)

以下内容对应 **0.2.0 的实际源码**。这里只记录实现和后续开发方法，尚未实现的事项会明确写为“后续建议”。以后调整程序时，以源码和新一轮测试结果为准。

<a id="dev-1"></a>

## 1. 技术栈与开发环境

| 层次 | 当前选择 | 在这个项目里的职责 |
| --- | --- | --- |
| 主语言 | Swift | 数据模型、窗口、编辑逻辑、图片处理、格式转换 |
| 界面框架 | AppKit | macOS 原生窗口、按钮、菜单、标签、滚动区、文件对话框 |
| 基础库 | Foundation | JSON、Data、URL、文件读写、计时器、进程、XML 解析等 |
| 文本系统 | NSTextView / NSTextStorage / NSLayoutManager / NSTextContainer | 富文本编辑、字体与段落、换行测量、字形绘制 |
| 绘图 | Core Graphics / AppKit 绘图接口 | 坐标变换、裁剪、位图、PDF 绘图上下文 |
| 图片编解码 | ImageIO + UniformTypeIdentifiers | PNG、JPEG、HEIC 编解码及文件类型标识 |
| PDF 辅助 | PDFKit | PDF 读取检查、页面缩略图和整页图片生成 |
| 并发 | DispatchQueue，即 GCD | 图片编码任务和磁盘清理任务放到后台队列 |
| 构建 | Bash + xcrun + swiftc | 编译、建立 App 包、写入配置、签名 |
| 测试 | Swift 可执行测试程序 + shell 脚本 | 核心模型、转换、界面内部逻辑和存储测试 |

当前是纯代码创建界面的原生 macOS 程序，没有 HTML 页面、WebView、HTTP 后端、数据库或云服务，也没有引入第三方 Swift 包。工程里没有 `.xcodeproj`、`Package.swift`、Storyboard 或 XIB；构建脚本直接编译 `Sources/*.swift`。使用 VS Code、Xcode 或其他文本编辑器修改源文件都可以，项目构建入口仍是 `build.sh`。

已编译的 App 日常运行不需要 Python、Java、Node 或 Xcode。**修改源代码并重新编译**需要 Apple 的 Xcode Command Line Tools，完整 Xcode IDE 不是目前的必需项。普通压缩 DOCX 导入还会使用 macOS 自带的 `/usr/bin/unzip`；不是所有文件处理都只经过 Swift 内存代码。

本机已验证环境：arm64，macOS 26.6.1，Apple Swift 6.3.3，macOS SDK 26.5，Command Line Tools 路径为 `/Library/Developer/CommandLineTools`。App 编译时显式设定 macOS 13.0 为最低目标，但**没有在 macOS 13～25 的每个版本实测**。编译器版本 6.3.3 与脚本的 `-swift-version 5` 不矛盾：前者是编译器版本，后者选择语言兼容模式。

开发机环境检查：

~~~bash
xcode-select -p
xcrun swiftc --version
xcrun --sdk macosx --show-sdk-version
uname -m
~~~

如果机器没有 Command Line Tools，手动运行 `xcode-select --install` 并完成系统安装提示；已有可用工具链就不需要重复安装。

<a id="dev-2"></a>

## 2. 目录地图和阅读顺序

~~~text
PaperDesk/
├── Sources/
│   ├── main.swift                 应用入口、启动/退出、Finder 打开文件
│   ├── Models.swift               文档/页面/对象、工程 JSON 与校验
│   ├── WorkspaceController.swift  所有文档窗口和恢复流程
│   ├── EditorController.swift     一份文档的界面、命令、保存、撤销
│   ├── CanvasView.swift           纸张绘制、命中检测、拖动、平移、文字编辑覆盖层
│   ├── ImageActions.swift         裁剪、拼图、图片导出相关界面
│   ├── ImageTools.swift           图片解码、裁剪、缩放、编码、目标大小搜索
│   ├── PDFExporter.swift          PageDrawing、A4 PDF、整页图片
│   ├── Conversion.swift           DOCX/Markdown、分页、XML、ZIP
│   └── StorageManager.swift       缓存/恢复文件管理和存储面板
├── Tests/
│   ├── TestMain.swift             核心测试入口
│   ├── EditorSmoke.swift          内部界面测试入口和离屏截图
│   ├── CanvasNavigationTests.swift 平移、缩放中心、预览缓存
│   ├── WorkspaceTests.swift       多文档、另存为、恢复隔离
│   └── StorageTests.swift         独立存储测试入口
├── build.sh / run.sh              编译 / 启动
├── test.sh / test-ui.sh / test-storage.sh
├── build/PaperDesk.app            编译产物，可再生成
├── work/                         开发缓存和测试输出，可再生成
├── README.md                     使用方法、实现讲解与后续开发手册
├── STATUS.md                     实际验证记录、当前限制、下一步
├── PLAN.md                       需求范围和分阶段计划
├── CONVERSION.md                 格式转换能力边界
├── FEATURES-VALIDATION.txt        0.2.0 测试记录
├── THEME-VALIDATION.txt           0.1.1 配色测试记录
├── VALIDATION.txt                 首版核心测试记录
└── Preview.png                   示例界面离屏渲染图
~~~

建议第一次按以下顺序读：

1. `Models.swift`：先认识程序处理的数据。
2. `main.swift` → `WorkspaceController.swift`：理解启动后是谁创建了谁。
3. `EditorController.configureUI()` / `configureCanvas()`：看按钮和回调如何接上。
4. `CanvasView.pageRect()`、`draw()`、`mouseDown/Dragged/Up()`：理解画面与坐标。
5. `CanvasView.startEditing()` → `PageDrawing.layout()`：理解文本。
6. `ProjectStore`、`saveProject()`、`checkpoint()`：理解持久化和撤销。
7. 再按兴趣阅读图片、转换、缓存和对应测试。

<a id="dev-3"></a>

## 3. 启动、事件循环和对象关系

`main.swift` 创建 `NSApplication.shared`，配置应用身份和 `AppDelegate`，最后调用 `app.run()`。这个调用进入 macOS 的事件循环：等待点击、按键、窗口事件，再分派给对应对象。GUI 不使用不断检查所有按钮状态的业务轮询。

系统通知 `applicationDidFinishLaunching` 后，AppDelegate 处理启动文件，创建编辑器，并安排恢复备份提示。Finder 的“打开方式”或双击工程文件会经 `application(_:openFiles:)` 进入同一个工作区。

~~~mermaid
flowchart TD
    A["NSApplication / AppDelegate"] --> W["WorkspaceController"]
    W --> E1["EditorController：作业甲"]
    W --> E2["EditorController：作业乙"]
    E1 --> U["NSWindow + 原生控件"]
    E1 --> C["CanvasView"]
    C --> D["PaperDocument"]
    C --> T["编辑时的 NSTextView"]
    E1 --> S["ProjectStore / ImageTools / DocumentConversion / PDFExporter"]
    W --> K["StorageWindowController"]
~~~

每个 EditorController 包含自己的 CanvasView、当前文件 URL、已保存快照、撤销/重做栈和恢复文件。实际可编辑模型保存在 `canvas.document`；当前实现有 MVC 风格，但还没有把所有状态抽成独立 DocumentSession，也没有使用 Cocoa 的 `NSDocument` 文档框架。后续重构应从现有所有权出发。

按钮通常通过 `target + action` 连接到 `@objc` 方法，比如点击“添加 A4 页”触发 `addPage()`。画布则通过闭包通知控制器，如 `onWillChange`、`onChange` 和 `onSelection`。这样 CanvasView 不必知道保存对话框或窗口菜单如何实现。

Swift 的 `class` 是引用类型，`struct` 是值类型。工作区/窗口/视图使用 class；文档、页面、元素使用 struct。对象通过 ARC 管理生命周期，闭包里的 `[weak self]` 和编辑器的 `weak workspace` 用于避免互相强引用。关闭窗口还要主动停止 Timer；ARC 不等于任何引用环都会自动消失。

<a id="dev-4"></a>

## 4. 工程文件的数据结构

`PaperDocument` → `[PaperPage]` → `[PaperElement]` 是一个树状结构。元素目前只有两类：`text` 和 `image`。

| 数据 | 内容 |
| --- | --- |
| 文档 | 工程版本、标题、页面数组、缩放、页间距、四边页边距 |
| 页面 | UUID、元素数组 |
| 共同元素字段 | UUID、类型、x/y/width/height |
| 文字元素 | `textRTF: Data?`，保存文字和样式 |
| 图片元素 | `imageData: Data?`、原文件名、归一化裁剪矩形 |
| 图层顺序 | 由页面元素数组的顺序决定，越靠后越晚绘制 |

`.paperdesk` 实际是由 Codable 编码的 JSON。RTF 和图片是二进制 Data，JSONEncoder 会把它们编码成 Base64 字符串。Base64 是编码，不是压缩或加密；其文本长度通常约为二进制的 4/3。因此“单文件方便携带”有体积成本。

一个可以表示空白工程的结构示例：

~~~json
{
  "version": 1,
  "title": "学习用空白工程",
  "pages": [
    {"id": "A8C649C8-74D4-4A2F-9851-89D9B16CD160", "elements": []}
  ],
  "zoom": 1,
  "pageGap": 28,
  "margins": {"top": 42.52, "bottom": 42.52, "left": 42.52, "right": 42.52}
}
~~~

App 版本 `0.2.0` 与工程格式 `version: 1` 是不同概念。新增 margins 使用自定义 `init(from:)` 和 `decodeIfPresent`，缺少字段的旧工程仍能打开。破坏性修改不能只给结构体加字段：需要定义迁移规则、版本检查和旧样例测试。

持久化与会话状态的区别：

| 会保存到工程 | 目前不会保存到工程 |
| --- | --- |
| 内容、对象坐标、原图、裁剪、文字格式 | 当前选择的对象、正在编辑的光标 |
| 缩放、页间距、纸内四边距 | 视口滚动位置、平移模式、参考线开关 |
| 标题、页面 UUID 与顺序 | 撤销历史、窗口坐标、整个标签会话 |

改变缩放或页间距目前也会让文档显示“未保存”，因为这两项在 PaperDocument 内参与 `Equatable` 比较。这是当前设计，不是有内容偷偷改变。

<a id="dev-5"></a>

## 5. A4、单位和三套坐标

文档中用 point（点）保存版面坐标：

~~~text
1 inch = 25.4 mm
1 point = 1/72 inch
point = mm × 72 / 25.4

A4 宽 = 210 × 72 / 25.4 ≈ 595.276 pt
A4 高 = 297 × 72 / 25.4 ≈ 841.890 pt
~~~

`paperWidth` / `paperHeight` 是固定常量。Retina 屏幕的实际像素密度由系统处理，文档点数不应直接乘显示器的 backingScaleFactor 后再存盘。

要区分三个空间：

1. **纸张空间**：元素的 `x/y/width/height`，原点在这张纸左上角。
2. **操作台空间**：多张纸竖直排列后的 CanvasView 坐标，含纸外空隙。
3. **窗口可见区域**：NSScrollView 的 clip view，只显示大操作台的一部分。

设纸张在操作台上的原点为 `P`，纸内点为 `p`，缩放为 `z`：

~~~text
操作台坐标 = P + p × z
纸内坐标   = (操作台坐标 - P) / z
~~~

窗口事件先通过 `convert(_:from:)` 变成画布坐标，再经过 `localPoint()` 转成纸内坐标。拖动屏幕 100 点，在 200% 缩放下只应移动文档 50 点；漏掉除以 zoom 就会造成“放大后拖动距离不对”。

`isFlipped = true` 让画布使用向下为正的 y 轴；PDF 的绘图坐标需要另外翻转。修改绘图时应明确当前上下文，不要靠到处添加负号来试错。

两种留白也不同：

- `pageGap`：纸外、两页之间的视图设置；`pageRect()` 还预留页码标签区域，所以相邻纸边的可见距离不只是滑块数值。
- `margins`：纸内四边距；`contentRect` 由四个点值算出，至少保留 10 × 10 mm 的内容区。已有对象仍以纸边为坐标原点，改变边距不会平移旧对象。

<a id="dev-6"></a>

## 6. 绘制、选择、拖动与缩放

`CanvasView.draw()` 绘制操作台背景、纸张阴影和页码，再把图形上下文平移到该页原点并按 zoom 缩放，调用共用的 `PageDrawing.draw()` 绘制真正的图文。参考线、蓝色选框和缩放手柄是画布附加层，不属于导出内容。

`PageDrawing` 按元素数组顺序绘制。点击选择时反向遍历数组，先命中最后画出来的对象，因此重叠图片能选到最上层。置顶/置底就是重新排列数组，不需要维护另一份 z-index。

一次对象拖动的过程：

1. mouseDown 记录鼠标起点、原始元素矩形、来源页面与选择集合。
2. 第一次真正 mouseDragged 时才记录撤销快照。
3. 每次从“本次位置减起点”计算位移，再加到原始矩形上，避免累计增量误差。
4. mouseUp 决定是否跨页；若跨页，先换算来源页与目标页原点差，再把元素移到目标页面。
5. 最后把对象限制在纸张边界内，刷新状态。

右下角手柄同样使用原始矩形和鼠标差值计算尺寸。图片默认按原宽高比缩放，按 Shift 可自由缩放。手柄命中半径会除以 zoom，使屏幕上的点击区域不随页面缩放而大幅改变。

视图平移走另一条路径：修改 clip view 的滚动原点，经过 `constrainBoundsRect` 限制边界，再通知滚动条刷新；元素坐标不动。操作台宽度额外保留横向空间，因此缩小的纸张也能左右移动。

缩放前 `captureViewportAnchor()` 记录视口中心对应的页面 UUID 和纸内点；改 zoom、重算画布尺寸后，`restoreViewportAnchor()` 滚动到让该点仍靠近视口中心的位置。遇到边界时会受滚动范围限制，不保证每次都完全不动。

<a id="dev-7"></a>

## 7. 富文本编辑：没有自己重写输入法和排版器

每个文字框保存一段 NSAttributedString 的 RTF 数据。AttributedString 的含义是“文字 + 各段文字对应的字体、颜色等属性”，不是只有 plain text。

编辑时使用 AppKit 的传统文本系统：

| 对象 | 可以按本科课程概念理解为 |
| --- | --- |
| NSTextStorage | 带属性的文本数据 |
| NSLayoutManager | 字符到字形、换行和布局计算 |
| NSTextContainer | 可以放文字的几何区域 |
| NSTextView | 接收输入、显示光标和选择的交互视图 |

双击文字框时，`startEditing()` 建立这组对象，把真正的 NSTextView 覆盖在画布文字框上；`editingID` 让普通绘制跳过正在编辑的文字，避免绘制两份。编辑器的 frame 随页面缩放，但 bounds 和文字布局宽度仍使用纸内点数。

输入、粘贴或格式变化后，`textDidChange()` / `syncEditing()` 将内容写回元素的 RTF。Esc 或离开编辑状态时移除覆盖层，再由 PageDrawing 显示该文字框。

字体、字号、颜色等通过修改富文本属性实现；对齐和行距通过 NSMutableParagraphStyle 实现。范围使用 `NSRange`，Cocoa 常用 UTF-16 索引，不能随意拿 Swift 的 `String.count` 当同一单位，中文、emoji 和组合字符需要特别测试。

显示与导出时使用文字框的实际矩形进行 TextKit 布局。`PageDrawing.overflows()` 比较容器装下的字形范围和总字形数，发现装不下就画红框，并在 PDF/整页图片导出时拒绝静默截断。

这里没有贯穿全文的连续文本流。导入长文会先计算分页，再生成多个独立文字框；手动编辑某一框不会自动把后面的框全部重新排版。若要实现类似 Word 的自动续页，应先引入“连续正文/文本流”模型，再让多个页面容器共享文本流，不能只在溢出时复制文字框。

<a id="dev-8"></a>

## 8. 图片、裁剪、拼图与指定大小压缩

`ImageTools.decode()` 使用 ImageIO 读取主图，处理 EXIF 旋转/镜像，并返回方向正确的 CGImage；HEIF 主图索引不一定为 0，所以代码调用 `CGImageSourceGetPrimaryImageIndex`。输入文件和像素数量在解码前后都有检查。

图片在纸上的宽高只是排版尺寸。把图片框拖大不会提升原图分辨率，把框拖小也不会自动缩小工程里保留的原图。

裁剪采用**原图 + 裁剪参数**。例如 `(x:0, y:0, width:0.5, height:0.5)` 表示保留摆正原图的左上四分之一。参数归一化到 0～1，预览窗口大小改变也不会改变裁剪含义。显示和导出时才把它换算成像素矩形进行 cropping；“恢复完整图片”只需把裁剪参数恢复为 full。

拼图是自动设置已有图片对象的位置和尺寸，并没有立即把所有图片合成一个不可编辑位图。若内容区宽度为 W，列数为 c，间隙为 g：

~~~text
每格宽度 = (W - (c - 1) × g) / c
行数     = ceil(图片数 / c)
图片缩放 = min(格宽 / 原宽, 格高 / 原高)
~~~

等比放入格子后居中，最后仍可以逐张移动。需要一张合成图片时，再执行整页图片导出。

格式转换遵循 `原文件字节 → CGImage 像素 → 目标格式字节`，不是改扩展名。编码前转成 8-bit sRGB；PNG 保留 alpha，JPEG/HEIC 先铺白色底。当前实现不承诺完整保留原图 EXIF、GPS、广色域/HDR 或原始色彩配置。

“压到 200 KB”是一个编码结果约束，文件大小无法只通过公式精确预测。实现流程：

1. 先按当前像素尺寸和较高质量编码，检查实际 Data.count。
2. JPEG/HEIC 若超限，测试较低质量；能满足时进行 8 轮类似二分的质量搜索。
3. 保留的候选必须是实际编码后不超限的数据；编码器大小不一定严格单调，因此不承诺数学上的全局最高画质。
4. 若低质量仍超限，按文件大小比例估计缩小像素尺寸，再编码。
5. PNG 没有同样的有损质量旋钮，主要依靠缩小尺寸；最多循环 48 轮，仍不满足就报错。

用于估计尺寸缩小比例的核心项是 `sqrt(目标字节数 / 当前字节数)`：像素数大致随宽高缩放系数的平方变化。它只是下一次尝试的估计，最终是否成功永远以真正文件字节数为准。

<a id="dev-9"></a>

## 9. PDF、DOCX、Markdown 的实现路径

这几个格式的转换不是在不同扩展名之间直接换壳，而是以 PaperDocument 为中间模型：

~~~text
DOCX ─────┐                       ┌─ .paperdesk：继续编辑
Markdown ─┼─ 解析/分页 → 文档模型 ─┼─ PDF：固定版式
TXT ──────┘                       ├─ DOCX：文字和图片内容交换
手工图文编辑 ─────────────────────└─ Markdown + 图片资源目录
~~~

**PDF。** `PDFExporter.write()` 创建固定 A4 mediaBox 的 CGContext，逐页 beginPDFPage/endPDFPage，调用与屏幕共用的 PageDrawing。绘制使用原始纸内坐标，不读取画布 zoom、滚动原点或 pageGap，所以改变查看方式不会改变 PDF 的纸张大小。文字绘制为文本/字形内容，图片绘制为图像；没有把整页先截图后塞进 PDF。

PDF 文本标记写入 ActualText，但系统字体的 ToUnicode 和阅读器实现仍可能影响中文复制。整页另存图片的路径不同：先生成该页 PDF，再通过 PDFKit 按指定大小栅格化。

**DOCX 导出。** DOCX 是带约定目录结构的 ZIP 容器，正文主要是 OOXML。程序生成 `word/document.xml`、资源关系 `.rels`、`[Content_Types].xml` 和 `word/media/*.png`；文字写成段落和 run，图片写成 drawing 并通过 relationship ID 引用资源。页面间写分页符，四边距写 pgMar。文档位置单位为点，DOCX 边距用 twip（1 点 = 20 twip），图片尺寸使用 EMU（1 点 = 12700 EMU）。

`StoredZIP` 自行生成未压缩 ZIP 条目、CRC32 和中央目录。未压缩 ZIP 仍是合法 ZIP；图片资源本身已是 PNG，并不意味着导出的 DOCX 只是文本或图片附件占位。

**DOCX 导入。** `ReadZIP` 检查中央目录和大小，method 0 条目直接读；method 8 的 Deflate 条目通过 `Process` 调用系统 unzip，把指定条目读入 Pipe。Process 设置参数数组，不经 shell 执行拼接命令；读取后再检查长度和 CRC。XMLParser 将 XML 解析成一个简化树，读取关系、段落、部分样式、图片和单节边距，然后生成 FlowBlock。它不是完整 Word 排版引擎。

**Markdown。** 自定义行/块处理识别基础段落、标题、列表、代码块、图片与本项目分页标记，行内样式借助 Foundation 的 Markdown 解析。图片只读取文件所在目录及其子目录中的安全相对路径，限制目录越界，也不下载网络图片。导出按阅读顺序输出文字，图片写入独立资源目录并生成链接。

**分页。** `paginate()` 对剩余文本建立 NSTextContainer，计算本页剩余矩形能容纳的字形和字符范围；切出这些字符生成文字框，继续处理剩余内容。图片按内容区缩放，当前页放不下就开下一页。真正的字形度量来自系统文本布局，不是“每页固定 1000 个字”。

保存为 DOCX/Markdown 时按元素的 y、x 排序输出阅读顺序，保留内容的能力与保留任意自由坐标是两回事。复杂表格、公式、多节布局、浮动环绕等兼容边界仍见 [CONVERSION.md](CONVERSION.md)。

<a id="dev-10"></a>

## 10. 保存、撤销、恢复与多窗口

**保存。** 先同步正在编辑的文字，再验证模型；JSON 编码成功后通过 `Data.write(options: .atomic)` 写入。控制器只在成功后切换 currentURL、更新 savedDocument、清除本份恢复备份。失败不能先把 dirty 清掉。atomic 降低目标文件写到一半被留下的风险，不等于已经实现版本历史、跨文件事务或所有断电场景下的备份保障。

**另存为。** 同一条保存路径，多一个强制选择目标文件的步骤。成功后当前标签继续编辑副本，原文件保持原字节，除非用户选择了同一路径并确认覆盖。当前控制器还检查其他标签文件和所有活动恢复路径，避免相互覆盖。

**撤销。** 普通文档操作记录 PaperDocument 快照，checkpoint 最多保留 40 个；撤销把当前状态放入 redoStack，再恢复 undoStack。新操作会清空重做栈。文字正在编辑时优先使用 NSTextView 的 UndoManager。Swift Array/Data 的写时复制能减少部分立即拷贝，但不能把 40 份含大量图片的历史当成“没有内存成本”。

**dirty。** 通过 `canvas.document != savedDocument` 判断当前状态是否与上次保存一致。该比较包括文档内的显示设置，也可能扫描大量数据；后续可考虑修订号和更细粒度的状态管理。

**自动恢复。** 每个编辑器有自己的 UUID 文件和 5 秒 Timer，dirty 时写整个工程备份。它不是每按一个键立即持久化，不能保证保留崩溃前最后几秒，也不是后台增量日志。启动时可恢复多份备份为不同标签；用户暂不恢复时保留文件。

**退出。** WorkspaceController 逐一询问有修改的文档。所有文档同意退出后，才统一清理剩余恢复备份；中途取消不会把尚未关闭文档的恢复文件提前全部删掉。

**多标签。** 每个文档本身是一个真实 NSWindow + EditorController，通过 `addTabbedWindow` 交给 AppKit 组合成系统标签。标签切换不用把一份模型复制到同一个编辑器，因此撤销、保存路径、选择状态天然按控制器分开。窗口变为 key 时更新菜单目标，防止快捷键操作上一份作业。存储面板使用 NSPanel；⌘W 根据当前 keyWindow 关闭。

打开同一路径时会检查规范化后的文件路径和活动恢复路径，优先激活原有编辑器。当前未实现关闭后恢复整个已保存窗口/标签会话；自动恢复针对未保存工程内容。

<a id="dev-11"></a>

## 11. 缓存、内存与线程边界

三类数据要分开理解：

| 数据 | 位置 | 清理含义 |
| --- | --- | --- |
| 原始图片/文字 | 工程文件及 PaperDocument | 用户内容，预览清理不能删除 |
| 解码后图片缓存 | 每个 CanvasView 内存字典 | 可从原图和裁剪参数重新生成 |
| 磁盘缓存/恢复备份 | Caches/PaperDesk 与 Application Support/PaperDesk | 可重建缓存与可能有价值的未保存内容分别处理 |

解码缓存按元素 UUID 索引，大小估算为 `bytesPerRow × height`。例如一张 4000 × 3000、4 字节/像素图片，仅像素就约 48 MB，磁盘上的 JPEG 可能只有几 MB。预览大小不是整个 App 进程占用，还没有计入原始字节、RTF、历史、对象和系统图形资源。

`rebuildImages()` 只为当前可见页面补充解码图片。但已经看过的页面缓存并不会自动按 LRU 淘汰，所以它还不是具有固定内存预算的缓存系统。`clearImageCache()` 清空预览而不主动安排立刻重绘；下一次需要显示时重新生成。`invalidateImages()` 则用于内容改动后清空并安排重绘，二者用途不同。

存储模块只枚举和清理应用指定目录，不跟随符号链接，不把任意用户路径当缓存。活动恢复路径受保护，删除旧备份需要单独选择和确认。当前 App 的主要图片预览在内存里，磁盘缓存目录显示 0 是正常结果；面板也不管理源码的编译缓存。

当前线程分工：

| 在主线程完成 | 在后台队列完成 |
| --- | --- |
| 窗口、输入、模型修改和绘图 | 图片最终压缩/编码及输出写入 |
| 图片导入/首次解码、裁剪预览准备 | 存储目录扫描和磁盘清理 |
| 工程 JSON 保存与定时恢复写入 | 后台完成后通过 main queue 更新界面 |
| DOCX/Markdown 导入导出、PDF 导出 | — |

因此大图首次导入、大文件转换、整份自动恢复仍可能让界面短暂停顿。后续优化不能把整个 EditorController 扔进后台线程：应该先在主线程获得一致的数据快照，后台处理纯数据或合适的图像 API，回到主线程更新状态，并处理任务期间切换/关闭文档、取消和失败的情况。TextKit/AppKit 绘制需要单独审查线程使用方式。

<a id="dev-12"></a>

## 12. 从 Swift 源码到可双击的 .app

`build.sh` 做五件事：

1. 用 xcrun 找 macOS SDK，用 uname 获取当前架构。
2. swiftc 编译全部 Sources 文件并链接系统 frameworks。
3. 生成 `Contents/MacOS/PaperDesk.new`，成功后替换正式可执行文件。
4. 写出 `Contents/Info.plist`，声明入口、名称、版本和支持的工程类型。
5. 执行 `codesign --force --deep --sign -`，生成本机临时签名。

M2 上当前编译命令的关键部分：

~~~bash
xcrun swiftc -swift-version 5 -O \
  -target arm64-apple-macosx13.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path "$PWD/work/module-cache" \
  -framework AppKit -framework PDFKit \
  -framework ImageIO -framework UniformTypeIdentifiers \
  Sources/*.swift -o build/PaperDesk.app/Contents/MacOS/PaperDesk.new
~~~

这是阅读脚本用的简化命令；日常完整构建直接运行 `./build.sh`，它还负责目录、配置和签名。`-O` 开启优化，`-target` 指定 CPU 和部署目标，`-sdk` 指向系统 API 定义/链接资料，`-module-cache-path` 保存编译模块缓存。

生成的可执行文件是原生 Mach-O。当前包在 M2 上为 arm64，不依赖 JVM、Python 解释器或浏览器运行时；也不是同时含 Intel 与 ARM 的 Universal Binary。脚本虽然能识别 x86_64 主机，Intel 构建并未在本项目验收中验证。

~~~text
PaperDesk.app/
└── Contents/
    ├── Info.plist
    ├── MacOS/
    │   └── PaperDesk
    ├── Resources/
    └── _CodeSignature/
        └── CodeResources
~~~

.app 在磁盘上是一个有约定结构的目录，Finder 把它显示成一个应用；右键“显示包内容”可以看到内部文件。Info.plist 告诉 macOS 启动哪个可执行文件，并声明 `local.paperdesk.document` 和 `.paperdesk` 扩展名，所以系统可以把工程交给应用的 openFiles 回调。

当前签名是 ad hoc（`--sign -`），用于本机使用和检查代码完整性，不包含 Developer ID 开发者身份，也没有完成 Apple 公证。未来面向其他用户正式分发，需要另做身份签名、公证和分发验证；创建 .app、做 ZIP、开发者签名、公证是不同步骤。

`run.sh` 比较 Sources/build.sh 和可执行文件的修改时间，必要时构建，然后调用 `open`。**它不会自动结束旧进程**：程序已运行时再次 open 可能只激活旧程序。改完源代码后应先保存作业、退出旧 App，再 build/run；运行中的进程不会因为磁盘文件更新就自动加载新逻辑。

<a id="dev-13"></a>

## 13. 日常开发、调试与交付流程

推荐每次只做一个可验收的小改动：

1. 读 STATUS 的已知限制，明确修改范围和复现步骤。
2. 保存当前作业，保留旧的可运行 App 或源码版本。
3. 修改负责该功能的文件，不同时重写不相关模块。
4. 跑相关测试，构建，再退出旧进程启动新版检查真实操作。
5. 更新 README/STATUS；交付时更新包内版本和测试记录。

常用命令（在项目目录）：

~~~bash
./build.sh
./run.sh
file build/PaperDesk.app/Contents/MacOS/PaperDesk
codesign --verify --deep --strict --verbose=2 build/PaperDesk.app
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/PaperDesk.app/Contents/Info.plist
~~~

需要从终端观察运行日志时，先退出已有实例，再直接运行：

~~~bash
./build/PaperDesk.app/Contents/MacOS/PaperDesk
~~~

不要同时启动多个独立进程来测试同一恢复目录；程序内“多窗口”和多个 OS 进程是不同概念。

目前未提供 LLDB 专用 Debug 构建脚本。需要源码断点时，可参考 build.sh 的源文件/框架参数单独使用 `-g -Onone` 编译 Debug 产物，再通过 LLDB 启动；不要把 release 编译的 `-O` 结果当成没有优化的逐行调试环境。

编译缓存可换到项目外，并在后续命令保持同一绝对路径：

~~~bash
export PAPERDESK_BUILD_CACHE="$PWD/../PaperDesk-compiler-cache"
./build.sh
./test-ui.sh
~~~

模块缓存可能含绝对路径。移动工程后不要把旧缓存移动到新位置并继续复用；换一个新的缓存目录重新生成通常更可靠。编译缓存、build 产物和用户的恢复备份不是一回事。

交付只需要 App 时，可使用系统 ditto：

~~~bash
ditto -c -k --keepParent build/PaperDesk.app ../PaperDesk-app.zip
unzip -tq ../PaperDesk-app.zip
~~~

需要连同源码交付时，在父目录打包整个 PaperDesk 文件夹，先排除/移走编译缓存和测试中间产物，保留构建脚本、Sources、Tests 和文档。本项目交付包采用“App + 源码 + 文档”，不是安装器，解压后即可找到 App。

源码仓库为 [gruTGU/PaperDesk](https://github.com/gruTGU/PaperDesk)，主分支为 `main`，当前发布标签为 `v0.2.0`。`.gitignore` 排除了 `build/`、`work/`、macOS 元数据和个人 `.paperdesk` 工程；App 通过 Releases 提供，不放进源码提交。克隆会带上 Git 历史；下载交付压缩包不会附带 `.git`。

继续开发时，先检查 `git status`，为一个具体改动新建分支，例如 `git switch -c improve-image-cache`；修改并完成相关自检后，用 `git diff` 检查差异，再用 `git add <具体文件>` 和 `git commit` 提交，最后 `git push -u origin improve-image-cache`。按独立改动提交，方便回溯和比较；不要把个人作业样本、缓存和大体积图片混进代码历史。首次上传之前的开发过程没有逐次提交，`v0.2.0` 保存的是当前完整快照。

<a id="dev-14"></a>

## 14. 测试覆盖和应如何扩展

| 入口 | 主要覆盖 | 不代表什么 |
| --- | --- | --- |
| `test.sh` | JSON 校验与失败保护、图像编码、PDF、DOCX/Markdown | 不等于所有 Word 排版完全兼容 |
| `test-ui.sh` | 文本编辑内部调用、撤销、多文档保存保护、边距、平移、对比度 | 不等于用户真实鼠标/输入法全流程 |
| `test-storage.sh` | 临时目录里的删除范围、路径/链接检查、恢复保护 | 不需要拿用户真正备份做破坏性测试 |
| 真实桌面检查 | 输入、弹窗、焦点、标签、快捷键和可见布局 | 不能覆盖所有文件及系统版本 |

0.2.0 已记录 73 项核心断言、18 项存储断言，以及内部界面测试和主要新增功能的桌面验证。HEIC 测试因已有环境问题明确跳过；不要将跳过计入通过数量。完整记录在 FEATURES-VALIDATION.txt。

核心测试默认包括 HEIC，若要复现本次受限环境的其他测试：

~~~bash
PAPERDESK_SKIP_HEIC=1 ./test.sh
./test-ui.sh
./test-storage.sh
~~~

保留核心测试样例供观察：

~~~bash
PAPERDESK_SKIP_HEIC=1 PAPERDESK_TEST_OUTPUT="$PWD/work/core-samples" ./test.sh
~~~

未指定 PAPERDESK_TEST_OUTPUT 时，核心测试用临时目录并自动清理；指定后保留。界面截图在 `work/ui-test/interface.png`。测试入口是带 `@main` 的小程序和辅助函数，目前没有引入 XCTest、Swift Testing、持续集成或 UI 自动化工程。

新增模型/转换逻辑时，把“结果对不对、失败是否保护原件”写成断言。新增界面命令时，再检查真实焦点和菜单目标。例如只调用 `addText()` 成功不能证明用户点击按钮后光标就一定处在正确位置。

不要把生产入口 `Sources/main.swift` 和测试的 `@main` 一起编译成同一个程序；test-ui.sh 因此显式列源文件，排除 main.swift。新增源文件时，build.sh 的通配符会自动包含，但相关测试脚本的显式清单也需要更新。

<a id="dev-15"></a>

## 15. 常见修改应从哪里入手

| 想调整什么 | 先看哪里 | 必须一起考虑 |
| --- | --- | --- |
| 默认字体、字号和段落 | TextStyle.make、字体下拉框、addText | 已有文字是否改变；RTF 导出是否一致 |
| 默认页边距或缩放 | Models 的默认值、CanvasView、右侧字段 | 新文档默认与旧工程迁移分开 |
| 纸外留白或纸张排列 | pageRect、updateSize | 命中检测、跨页拖拽、缩放锚点、编辑覆盖层 |
| 对齐、吸附、等距分布 | CanvasView 拖动 + EditorController 命令 | 以纸内坐标计算；一次操作只记一个撤销节点 |
| 新增元素类型 | ElementKind、PaperElement、PageDrawing | Codable 迁移、选择/编辑、导出和失败提示 |
| 改图片格式或压缩策略 | ImageFormat、ImageTools.export | 透明通道、颜色、方向、实测字节上限 |
| 改拼图模板 | ImageActions.makeCollage | 四边距、行列间距、多选、撤销 |
| Word/Markdown 兼容性 | Conversion 的解析、FlowBlock、分页、导出 | 先准备用户样例和往返测试，别只检查文件能打开 |
| 标签菜单/窗口状态 | WorkspaceController、createMenu、main | keyWindow、取消关闭、恢复文件是否串用 |
| 保存/恢复策略 | ProjectStore、saveProject、writeRecovery | 原子写、错误时 dirty、旧格式兼容、多窗口 |
| 缓存上限 | CanvasView 的图片字典、StorageManager | 原图不能删除；资源是否仍在其他窗口使用 |
| 配色/字号/布局 | configureUI、AppKit appearance | 深浅色环境、窗口最小尺寸、文字对比度 |
| App 名称、版本、图标 | build.sh 的 Info.plist 和 Resources | 重新构建签名；Bundle ID 与工程类型关联 |

修改普通文档内容常见顺序是：同步/结束当前文字编辑 → checkpoint → 修改模型 → 必要时 invalidateImages → didChange → refreshSelection。并非所有查看操作都要写撤销；平移视口就不应写入内容历史。

如果以后接入 SwiftUI，可先保留 CanvasView/TextKit 和业务模块，通过 NSViewRepresentable 做桥接，再逐步替换面板。若改用 Python/Java/TS，模型与算法思想可以复用，但 AppKit/TextKit/ImageIO 接口需要重写或桥接；当前程序并不具备跨平台 UI 层。

<a id="dev-16"></a>

## 16. 后续完善建议与验收条件

以下是建议顺序，**未在 0.2.0 实现**，也不是本次需要继续开发的隐含任务。

| 优先级 | 建议 | 完成时应看到的证据 |
| --- | --- | --- |
| 1 | 输入体验与真实作业样例 | 中文输入法、长文本、字体切换、撤销、焦点、DOCX 样例逐项可复现通过 |
| 1 | 大图/转换/自动恢复性能 | 记录耗时和峰值内存，大图操作时窗口仍响应；可取消、可报错 |
| 1 | 更可靠的恢复体验 | 多文档异常退出后可预览选择恢复，保存/取消不丢原件，失败有明确提示 |
| 2 | 图片缓存内存预算 | 达到上限后淘汰可重建预览；浏览很多页后内存不无限累积 |
| 2 | 文档状态模块拆分 | 拆出 DocumentSession/命令层，界面代码更短，回归测试不变 |
| 2 | 图文排版辅助 | 对齐线、吸附、分布、模板，操作能撤销，缩放不改变结果 |
| 2 | HEIC 本机正常环境验收 | 真实 iPhone 样例方向正确，能编码/重开/压缩；失败则决定替代编码器 |
| 3 | 自动文字续排 | 一个连续文本流跨多页增删，后续页面重排、撤销和导出一致 |
| 3 | 更丰富 DOCX 支持 | 以明确的表格/列表/页眉等样例限定范围，不承诺一次支持全部 OOXML |
| 3 | 正式打包分发 | 图标、版本发布、目标系统实测、Developer ID 签名、公证等按分发需求落实 |

性能方面最值得先测的路径是：refresh 每次检查所有文字框溢出、文本变动时反复编解码 RTF、整个文档的相等比较、每 5 秒整份 JSON 恢复写入、首次图片解码。先用实际样例测量，再决定缓存、节流、后台任务或模型重构；不要只靠“再开几个线程”。

未来若把 JSON+Base64 改成“manifest.json + assets/”的包结构，可以减少 Base64 体积和原图重复写入，但会引入多文件一致性、迁移与资源垃圾回收问题，需要独立设计版本和失败恢复。

<a id="dev-17"></a>

## 17. 排错与交接清单

| 现象 | 建议先检查 |
| --- | --- |
| 改代码后 App 没变化 | 是否只激活了旧进程；先保存退出，再重新 build/run |
| 编译找不到 SDK/模块 | xcode-select、xcrun 输出；是否复用了移动过的模块缓存 |
| 界面卡顿 | 主线程是否在解码图片、解析 DOCX、测量全文或写恢复文件 |
| 缩放后拖动不准 | 窗口/画布/纸内坐标是否混用；是否漏除 zoom |
| 文本框有红边 | 实际字形是否装不下；字体回退或行高改变是否导致溢出 |
| 看得到文字却输入不了 | 是否处于平移模式；是否双击进入 NSTextView；firstResponder 是谁 |
| 页边距变了旧文字不动 | 当前设计只调整内容区，不自动重排已有对象 |
| HEIC 编码失败 | 正常桌面环境的系统编码服务和真实样例，不要改扩展名假装成功 |
| 缓存清理后又增大 | 再次绘制会解码，当前没有 LRU 上限 |
| 存储面板磁盘缓存为 0 | 当前主要预览缓存在内存里，没有必须持续生成的磁盘缓存 |
| PDF 复制中文与原字符串不同 | 原有字体 ToUnicode 映射限制；用工程/RTF/DOCX 保存可编辑原文 |
| 换目录后运行失败 | 脚本执行权限、旧缓存路径、是否运行了旧位置的 App |

后续自己或交给其他开发者时，至少提供：README、STATUS、PLAN、Sources、Tests、复现样例、系统/编译器版本和最近测试日志。应用源码目录不保存用户全部作业，不要误以为分享源码包就包含了当前打开的所有文件。

可直接作为下次开发请求的模板：

~~~text
请先阅读 README.md、STATUS.md、PLAN.md。
当前版本：0.2.0；平台：Mac Apple 芯片。
本次只做：[一个具体需求或可复现问题]。
样例/复现步骤：[文件位置与操作步骤]。
预期结果：[可检查的具体表现]。
保留：旧 .paperdesk 兼容、A4 PDF、已有内容和其他窗口的保存状态。
完成后：运行相关测试，说明哪些已实测、哪些尚未验证，并更新文档。
~~~


<a id="dev-18"></a>

## 18. 用这个 App 理解操作系统

这一节把前面的实现与操作系统课程联系起来，不要求先掌握 Swift 的具体语法。

### 18.1 文件、可执行程序和进程是三件事

磁盘上的 `PaperDesk.app` 是应用包，`Contents/MacOS/PaperDesk` 是 Mach-O 可执行文件，运行起来的 PaperDesk 才是一个进程。进程拥有虚拟地址空间、线程和打开的文件等运行资源。

双击 App 时，可按以下教学模型理解：

~~~text
Finder / Launch Services
    ↓ 识别应用包、入口和文件关联
系统装载可执行文件，动态链接器 dyld 准备依赖
    ↓
进入程序入口，创建 NSApplication
    ↓
启动主事件循环，创建窗口
~~~

Swift 代码编译成机器码，AppKit、ImageIO 等由系统提供。链接系统框架不等于把整个框架源码复制进自己的 App。修改磁盘上的源文件没有改变已运行进程里的指令；重新编译后的新可执行文件也需要在新启动的进程中使用。这解释了为什么 `run.sh` 有时只把旧窗口激活，必须退出再启动才看到改动。

当前多个文档标签位于同一个 PaperDesk 进程内，并没有采用浏览器常见的多进程页面隔离。一个标签对应一个控制器和窗口对象，不对应一个独立进程；主线程长时间忙碌时，其他标签通常也会受影响。

### 18.2 鼠标点击是怎样到达业务代码的

忽略底层驱动细节，一次点击的路径可以画成：

~~~text
输入设备 → macOS 窗口系统 → 应用事件队列
    → AppKit 分派 → 窗口/控件/first responder
    → action 或 mouseDown → 修改模型
    → 标记需要重绘 → 绘制 → 系统合成窗口画面
~~~

按钮有 target/action，画布重写鼠标事件，文字框需要成为 first responder 才能接收键盘输入。窗口显示在前台不代表某个文字框已经拥有键盘焦点。这也是检查“能点但打不了字”时要看焦点，而不只是看进程是否活着的原因。

`needsDisplay = true` 的意思是告诉框架“这块画面需要更新”，不是马上直接执行一遍完整绘图。系统可以合并多次更新，避免每次鼠标事件都重复提交整幅画面。本项目未自己编写 GPU 着色器；几何、文字、位图和窗口合成主要交给系统绘图框架。

一般界面更新由主线程串行处理。若事件回调在主线程同步压缩一张大图并耗时两秒，就可能两秒无法及时处理下一次点击或重绘。普通模态对话框则会运行框架管理的模态事件处理，不能简单把“调用 runModal”与“程序死循环”混为一谈。

### 18.3 线程、后台队列与竞态

进程是资源与隔离边界；线程是执行代码的一条执行流，同一进程的多个线程共享地址空间。本项目使用 GCD 把工作提交到队列，由运行时安排执行，不是每按一次按钮就自己创建一条永久线程。

图片导出可以拆为：

~~~text
主线程：读取参数、确定输出目标、取得待处理图像
后台：尝试编码质量/尺寸、写出图片文件
主线程：显示结果、恢复按钮状态或报告错误
~~~

后台队列能让主线程继续处理交互，但不意味着任务更快，更不意味着共享数据自动安全。比如后台正在读取某份文档，用户同时删除页面，若双方直接操作同一个可变数组就可能产生竞态。可采用“先形成一致快照，再处理快照”，并在返回结果时核对文档标识、修订号或任务状态。

当前代码以主线程管理可编辑模型，并只将部分独立任务移到后台。后续给导入/导出加并发时，需要同时设计取消、进度、错误返回和关闭窗口期间的任务归属，不能只加一句 async。

### 18.4 虚拟内存与图片缓存

操作系统把进程看到的虚拟地址映射到实际内存资源；应用分配对象与字节缓冲区，不直接管理物理内存条上的位置。使用更多内存并不等于马上崩溃，但内存压力、压缩或换页可能让整个操作变慢。

图像解码会把磁盘上的压缩表示展开为像素。4000 × 3000 的 4 字节像素缓冲区约 48 MB；多张原图、解码副本、导出中间图和撤销历史可同时存在。因此“磁盘工程 10 MB”不能推出“运行只占 10 MB”。

还有两种容易混淆的写时复制：

- 文档数组/Data 的值语义可能通过共享底层缓冲区减少立即复制；修改时才需要复制相关存储。
- 操作系统虚拟内存也有自己的映射与写时复制机制。

它们不是同一层的功能。当前撤销策略只需要理解为“保存逻辑快照，底层可能延迟复制”，不要据此保证内存常量不增长。

释放预览字典是在释放程序持有的可重建数据引用；内存分配器和系统资源回收不一定让活动监视器的进程数值立即等量下降。当前存储面板显示的是预览缓冲区估算，不是系统内存分析器。

### 18.5 文件写入：原子性、持久性和恢复

可以把保存分成三层：

1. **逻辑层**：这份文档是否有效，编码是否成功，保存成功后才清除 dirty。
2. **文件系统层**：避免用一半新字节覆盖旧文件；当前请求 Foundation 使用 atomic 写入。
3. **故障恢复层**：崩溃、断电、磁盘满后还能找回什么；当前有单独的定时恢复备份，但没有完整事务日志或多版本历史。

“原子写入”主要关注目标文件替换的一致性；“持久性”关注成功返回后数据在故障情况下能保留到什么程度。操作系统和设备可能有缓存，因此 atomic 不能直接等同于数据库已经完成所有持久化保障。

5 秒恢复计时器也是事件循环上的任务，不是一个精确实时钟。主线程忙碌、机器休眠或进程停止时，回调可能推迟；当前实现不能保证每五秒恰好写盘，也无法保存最后一个尚未执行备份回调之后的修改。

保存作业、缓存、恢复备份放不同目录，是根据数据价值和生命周期划分；不能仅因为某个文件“不在用户文稿目录里”就把它当可删除垃圾。

### 18.6 Pipe：DOCX 解压里的进程间通信

普通 DOCX 的 Deflate 条目使用一个子进程执行系统 unzip。子进程有自己的地址空间，不能直接把一个 Swift 数组指针交给父进程，所以通过 stdout 与 Pipe 传输字节。

~~~text
PaperDesk 父进程 ──参数──> unzip 子进程
PaperDesk 父进程 <──Pipe 字节流── unzip stdout
~~~

父进程分块读取，检查累计长度，最后确认退出状态与 CRC。Pipe 的缓冲区有限，若父进程先一直等待子进程退出却不读输出，而子进程因缓冲区写满无法继续，就可能互相等待。当前代码边读 stdout，之后再等待退出，符合这个生产者/消费者流程。

“用参数数组创建 Process”与“把用户路径拼进 shell 命令字符串”也不同。前者不让路径中的空格、分号等自动成为 shell 语法；本项目还处理了 unzip 自己的文件名通配符规则。不同层次的解析仍要分别考虑。

### 18.7 签名、权限和沙盒各管什么

| 概念 | 解决的问题 | 本项目现状 |
| --- | --- | --- |
| 普通文件权限 | 当前用户/进程能否读写这个位置 | 受系统权限限制，不需要管理员身份运行 |
| macOS 隐私控制（TCC） | 某些受保护资源是否允许该应用访问 | 仍由系统决定，原生应用不能自行绕过 |
| 代码签名 | 代码完整性及签名身份等 | 当前 ad hoc 签名，无 Developer ID 身份 |
| Apple 公证 | 面向分发的软件提交 Apple 检查流程 | 未实施 |
| App Sandbox | 通过 entitlement 等限制应用可访问资源 | 当前构建脚本未启用 App Sandbox |

外部开发工具给测试进程施加的执行限制，与 App 本身是否启用 App Sandbox 是不同的事。此前 HEIC 编码服务在受限执行环境失败，不能据此直接断言“Mac 不支持 HEIC”，也不能把未验证写成成功。

多个文档标签只做状态隔离，仍处于同一应用权限和地址空间内。对文件格式做体积/路径/数据校验是在保护解析边界；这些检查并不构成完整的安全审计或进程沙盒。

### 18.8 用一个完整操作串起来

以“打开图片 → 放到 A4 → 导出 PDF”为例：

1. 系统文件对话框返回 URL，程序按当前权限读取文件字节。
2. ImageIO 解码并处理 EXIF 方向，应用得到像素缓冲区。
3. 模型保存原图和纸内矩形；框架绘图将它映射到屏幕。
4. 鼠标事件修改矩形，主线程标记重绘；滚动只改变视口。
5. 撤销快照和定时恢复负责编辑状态及崩溃恢复。
6. 导出代码取得模型，创建 A4 PDF 上下文，再按纸内坐标绘制。
7. 文件编码完成后写入磁盘，并在界面显示成功或错误。

在这一条路径里，就能同时看到事件驱动、坐标变换、压缩表示与像素表示、资源管理、状态快照和文件 I/O。它们的边界比某个语言的语法更值得先掌握。

<a id="dev-19"></a>

## 19. 配合源码学习的官方资料


- [Swift 官方语言指南](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/)：类型、协议、错误处理和泛型。
- [Swift ARC](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/automaticreferencecounting/)：理解 weak 和闭包引用关系；对应控制器、计时器和回调。
- [NSApplication](https://developer.apple.com/documentation/appkit/nsapplication)：对应应用入口和事件循环。
- [Cocoa 文本系统结构](https://developer.apple.com/library/archive/documentation/TextFonts/Conceptual/CocoaTextArchitecture/TextSystemArchitecture/ArchitectureOverview.html)：对应本项目实际使用的 NSTextStorage/NSLayoutManager/NSTextContainer/NSTextView。归档文档仍适合了解这一组传统接口，不能当成新 TextKit API 的完整说明。
- [macOS Bundle 结构](https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFBundles/BundleTypes/BundleTypes.html)：对应 Contents、Info.plist、可执行文件与资源。
- [Apple 软件公证说明](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)：仅在后续需要正式分发时继续阅读。
- [Apple 并发编程：使用队列管理任务](https://developer.apple.com/library/archive/documentation/General/Conceptual/ConcurrencyProgrammingGuide/ThreadMigration/ThreadMigration.html)：理解线程与任务队列的区别。
- [Apple 虚拟内存概览](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/ManagingMemory/Articles/AboutMemory.html)：了解地址空间与虚拟内存；具体系统实现和限制以当前 macOS 为准。
- [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)：区分 App 沙盒、签名和普通权限。

学习时可以把这个项目当作事件驱动、数据建模、坐标变换、序列化、资源管理和文件格式解析的综合小项目。先做到能追踪一次“点击 → 模型改变 → 重绘 → 保存”的路径，再扩展复杂排版，会比一次阅读全部文件更有效。
