# dolmo paste

macOS 剪贴板管理器。常驻菜单栏，记住你复制过的东西，键盘直达。

## 构建与运行

```bash
./build.sh                                   # 产出 build/dolmo paste.app
cp -r "build/dolmo paste.app" /Applications/ # 建议装到这里，权限和开机启动才稳
open "/Applications/dolmo paste.app"
```

要求 macOS 14+，Xcode 命令行工具已安装。

## 快捷键

| 键 | 作用 |
|---|---|
| `⌘⇧V` | 唤起 / 收起历史浮窗 |
| 直接打字 | 搜索（支持中文 + 拼音首字母） |
| `↑ ↓` | 选择 |
| `Tab` | 切换类型过滤（全部 / 固定 / 文本 / 图片 / 文件） |
| `⏎` | 粘贴（保留格式） |
| `⇧⏎` | 纯文本粘贴 |
| `⌘1~9` | 快速粘贴前 9 条（按住 `⌘` 时行尾显示序号） |
| `⌘P` | 固定 / 取消固定（固定后永不过期） |
| `→` | 查看大图（图片行鼠标悬停也有预览，可滚轮 / 双指缩放） |
| `⌫` | 删除当前条 |
| `⌘,` | 设置 |
| `Esc` | 关闭（预览被缩放"钉住"时，第一次只收预览） |

菜单栏图标是橙子剪影（模板图，跟随菜单栏深浅）：左键打开历史，右键菜单（设置 / 清除 / 退出）。

## 主窗口

点击菜单栏图标打开主窗口（780×560，侧栏 180）：侧栏顶部是 Apple 账户状态，下面是四个分区 —— 通用 / 历史与存储 / 隐私 / 关于。
- 通用：样式选择（切换后下次唤起浮窗生效）、开机启动、唤起快捷键、粘贴设置；未授权辅助功能时顶部出现提示条
- 历史与存储：一行统计（条数 · 占用 · 起始日期）、文本/图片上限、大图阈值、图片文字识别（OCR）、存储位置、清除（确认框里二选一）
- 隐私：不记录的应用（+/− 增删）；没装的内置密码管理器收成一句脚注，装上后自动生效
- 关于：图标、版本、标语 + 6 条产品亮点

侧栏顶部照系统设置的样子显示当前账户（头像 + 姓名 + 「Apple 账户」），点击打开系统设置对应面板。数据全部取自本机已有记录，不联网：姓名和 Apple ID 读 `~/Library/Preferences/MobileMeAccounts.plist`，头像用 `dscl` 读系统账户头像并缩到 128 缓存到 Application Support（只取一次）。没登录 Apple 账户时退回本机账户，副标题显示「本机账户」。

主窗口配色跟随样式：系统样式用白底圆角分组 + 原生侧栏材质；dolmo 不用卡片，纸面上发丝线分行。

## 外观

两套样式（下次唤起浮窗时生效），共用同一套渲染代码，差异全部在 `UI/PanelTheme.swift`：

| | 系统样式 | dolmo design |
|---|---|---|
| 背景 | 原生 popover 材质 | 暖纸 `#FBFAF7` / 暖黑 `#1A1714` |
| 行 | 单行 36px，宽 640 | 单行 42px，宽 700，圆角 16 |
| 选中 | 系统强调色整行反白 | 浅色桃色 `#FCEBD6` / 深色暖灰 `#3D3027` |
| 强调色 | 跟随系统 accentColor | 橙 `#F28A1F` / `#FFA639`（取自图标），文字用 `#A9530B` |
| 固定图钉 | 灰 | 叶绿 `#5E9A4B` / `#8DC07A` |
| 搜索命中 | 加粗 | 加粗 + 橙色 |

通用细节：来源 App 图标做行首（不再重复写 App 名）、代码/命令用等宽字体、固定区后一条发丝线、行尾固定图钉槽保证时间列对齐、固定项不显示时间、单独网址去掉 `https://www.`、`⌘N` 平时隐藏；dolmo 下搜索框选中文字用橙色底。悬停预览卡与浮窗同材质同圆角，对齐悬停行，底部一行「尺寸 · 时间」，缩放时显示倍率。

UI 是用独立评审子 agent 循环迭代的（Lenny's Newsletter 那篇的方法）：`design-review/critic-prompt.md` 是固定评审 prompt，`rN/` 是每轮截图，`rN-critique.md` 记录采纳 / 不采纳。截图命令：`.build/release/DolmoPaste --snapshot design-review/rN`。

## 权限

首次启动会引导授予**辅助功能**权限。它只用于两件事：

1. 选中一条后模拟 `⌘V`，直接粘进你正在用的 App（不授权则只把内容放回剪贴板，需自己按 ⌘V）
2. 把浮窗显示在输入光标旁边（不授权则显示在鼠标附近）

关掉的话功能仍然可用，只是多按一次键。**数据只在本机**：`~/Library/Application Support/dolmo-paste/`，无任何网络代码。

## 隐私

- 遵守 `org.nspasteboard.ConcealedType` / `TransientType` 约定：密码管理器复制的密码**不会**入库
- 设置里可排除指定 App（Bundle ID 或"添加当前 App"）
- 自检方法：从密码管理器复制一次密码，打开历史确认它不在里面

## 代码结构

```
Sources/DolmoPaste/
  DolmoPasteMain.swift        入口
  AppDelegate.swift           菜单栏、启动引导、设置窗口
  Models/ClipItem.swift       SwiftData 数据模型
  Services/
    ClipboardMonitor.swift    changeCount 轮询（0.5s）、隐私过滤、去重
    ClipStore.swift           存储、图片落盘、上限淘汰、Vision OCR
    HotkeyManager.swift       Carbon 全局热键
    PasteEngine.swift         写回剪贴板 + 模拟 ⌘V
    Privacy.swift             ConcealedType 约定 + 默认排除名单
    Pinyin.swift              拼音索引
    AppSettings.swift         设置（UserDefaults）
    Toast.swift               轻提示（没授权时的降级说明）
  UI/
    MainWindowView.swift      主窗口：侧边导航 + 六个分区
    PanelTheme.swift          两套主题（system / dolmo）
    ClipPanelController.swift NSPanel 浮窗、键盘事件、滚轮路由、光标定位
    ClipPanelView.swift       SwiftUI 列表与搜索
    ClipPanelViewModel.swift  排序、过滤、选中
    ZoomState.swift           缩放 / 平移状态（预览与查看器共用）
    ImagePreviewPanel.swift   悬停预览：贴在主面板旁边的独立小面板，可缩放
    ImageViewer.swift         全屏大图查看器（→ 键 / 右键菜单）
```

## 图片查看

- **悬停预览**：鼠标停在图片行上，旁边浮出预览面板。滚轮 / 触控板双指上下滑缩放，双指捏合缩放，放大后拖拽平移，双击在「适应」和「原图 1:1」之间切换
- 它是**独立的小面板**而不是盖在列表上的浮层，所以既不挡点击，鼠标移过去也不会切换成别的条目
- 缩放之后就"钉住"不自动收起，直到按 `Esc`、换另一张图或关掉面板
- `→` 键 / 右键菜单「查看大图」打开全屏查看器，适合看清大截图

预览读的是**落盘原图**（不是 400px 缩略图），否则一放大就糊。

## 图标

应用图标和菜单栏图标是**同一套几何**：圆形果身 + 右上柳叶 + 叶子与果身之间一道缝（18×18 坐标，见 `AppDelegate.orangeSilhouette`）。
- 菜单栏：模板图，单色，跟随菜单栏深浅
- 应用图标：`tools/draw_icon.swift` 把同样的形状等比放大上色——纯白底 `#FFFFFF`、橙 `#FF9500`、叶绿 `#5EA84A`，缝露出底色

重新生成：`./tools/build_icon.sh`（不带参数即代码绘制；带一张 png 则走旧的裁白边 + 圆角流程）。改了剪影几何要两处同步。
替换 /Applications 里的 app 后图标有缓存，需要 `lsregister -f` + `killall Dock`。

## 当前状态

已完成（P0 + P1 大部分）：捕获（文本/RTF/图片/文件）、搜索（中文+拼音）、粘贴、纯文本粘贴、Quick Paste、Pin、上限淘汰、隐私过滤、来源 App（含图标）、光标处弹出、类型过滤、两套面板样式、截图 OCR、图片悬停预览可缩放、全屏大图查看、应用图标。

来源 App 图标在捕获时快照入库（32px PNG，约 15KB），App 关掉后也能显示；升级前的旧记录在启动时自动回填。

待办：
- 顺序粘贴栈（CleanClip 那种：连续复制，按顺序吐出）
- 分割复制（一次复制多行，拆成多条）
