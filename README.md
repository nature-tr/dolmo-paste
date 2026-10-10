# dolmo paste

macOS 剪贴板管理器。常驻菜单栏，记住你复制过的东西，键盘直达。

![platform](https://img.shields.io/badge/platform-macOS%2014%2B-black) ![swift](https://img.shields.io/badge/Swift-AppKit%20%2B%20SwiftUI-F05138) ![privacy](https://img.shields.io/badge/data-local--only-5E9A4B)

## 特性

- **全类型捕获** — 文本 / RTF / 图片 / 文件引用，自动去重，设上限自动淘汰
- **即刻搜索** — 中文原文 + 拼音全拼/首字母双索引，打字即搜；Tab 循环切换类型过滤
- **一步粘贴** — 写回剪贴板并模拟 `⌘V` 直接粘入原 App（需辅助功能权限），支持纯文本粘贴
- **Quick Paste** — `⌘1~9` 快速粘贴前 9 条
- **Pin 固定** — 固定常用片段，永不过期
- **图片查看** — 悬停预览（滚轮/捏合缩放、平移、双击适应）+ 全屏大图查看器
- **截图 OCR** — Vision 识别图片内文字，搜索可命中
- **两套主题** — 跟手系统样式 / 自研 dolmo design（暖纸、橙色强调）

**数据只在本机**（`~/Library/Application Support/dolmo-paste/`），无任何网络代码。

## 快速开始

要求 macOS 14+，已安装 Xcode 命令行工具。

```bash
git clone https://github.com/<your-name>/dolmo-paste.git
cd dolmo-paste
./build.sh                                    # 产出 dolmo-paste/build/dolmo paste.app
cp -r "build/dolmo paste.app" /Applications/  # 建议装到这里，权限和开机启动才稳
open "/Applications/dolmo paste.app"
```

首次启动会引导授予**辅助功能**权限，它只用于两件事：

1. 模拟 `⌘V`，把选中内容直接粘进你正在用的 App（不授权则内容只回到剪贴板，自己按 ⌘V）
2. 把浮窗显示在输入光标旁边（不授权则显示在鼠标附近）

关掉的话功能仍然可用，只是多按一次键。

## 快捷键

| 键 | 作用 |
|---|---|
| `⌘⇧V` | 唤起 / 收起历史浮窗 |
| 直接打字 | 搜索（支持中文 + 拼音首字母） |
| `↑ ↓` | 选择 |
| `Tab` | 切换类型过滤（全部 / 固定 / 文本 / 图片 / 文件） |
| `⏎` | 粘贴（保留格式） |
| `⇧⏎` | 纯文本粘贴 |
| `⌘1~9` | 快速粘贴前 9 条 |
| `⌘P` | 固定 / 取消固定 |
| `→` | 查看大图（图片行悬停也有预览） |
| `⌫` | 删除当前条 |
| `⌘,` | 设置 |
| `Esc` | 关闭 |

菜单栏图标是橙子剪影（模板图，跟随菜单栏深浅）：左键打开历史浮窗，点击图标打开主窗口；右键菜单有设置 / 清除 / 退出。

## 主窗口

点击菜单栏图标打开主窗口（780×560，侧栏 180），四个分区：

- **通用** — 面板样式（切换后下次唤起生效）、开机启动、唤起快捷键、粘贴设置
- **历史与存储** — 条数/占用统计、文本/图片上限、大图阈值、OCR 开关、存储位置、清除
- **隐私** — 不记录的应用（按 Bundle ID 排除）
- **关于** — 版本信息与产品亮点

### 外观

两套样式共用同一套渲染代码，差异全部收敛在 `UI/PanelTheme.swift`：

| | 系统样式 | dolmo design |
|---|---|---|
| 背景 | 原生 popover 材质 | 暖纸 `#FBFAF7` / 暖黑 `#1A1714` |
| 行 | 单行 36px，宽 640 | 单行 42px，宽 700，圆角 16 |
| 选中 | 系统强调色整行反白 | 浅色桃色 `#FCEBD6` / 深色暖灰 `#3D3027` |
| 强调色 | 跟随系统 accentColor | 橙 `#F28A1F` / `#FFA639`，文字 `#A9530B` |

### 图片查看

- **悬停预览**：鼠标停在图片行，旁边浮出独立小面板（不挡点击、不误切换）。滚轮/双指滑缩放、捏合缩放、放大后拖拽平移，双击在「适应」和「1:1」间切换
- 缩放后「钉住」不自动收起，`Esc`、换图或关面板才收
- **全屏查看器**：`→` 键或右键菜单「查看大图」
- 预览读**落盘原图**（非 400px 缩略图），放大不糊

## 隐私

- 遵守 `org.nspasteboard.ConcealedType` / `TransientType` 约定：密码管理器复制的密码**不会**入库（已适配 1Password、Apple 密码等主流管理器）
- 设置里可按 Bundle ID 排除指定 App
- 自检方法：从密码管理器复制一次密码，打开历史确认它不在里面

## 项目结构

```
dolmo-paste/
  Package.swift
  build.sh                    构建脚本（产出 build/dolmo paste.app）
  Resources/                  Info.plist、应用图标
  Sources/DolmoPaste/
    DolmoPasteMain.swift      入口
    AppDelegate.swift         菜单栏、启动引导、设置窗口
    Models/ClipItem.swift     SwiftData 数据模型
    Services/
      ClipboardMonitor.swift  changeCount 轮询（0.5s）、隐私过滤、去重
      ClipStore.swift         存储、图片落盘、上限淘汰、Vision OCR
      HotkeyManager.swift     Carbon 全局热键
      PasteEngine.swift       写回剪贴板 + 模拟 ⌘V
      Privacy.swift           ConcealedType 约定 + 默认排除名单
      Pinyin.swift            拼音索引
      AppSettings.swift       设置（UserDefaults）
      Toast.swift             轻提示
    UI/
      MainWindowView.swift    主窗口：侧边导航 + 分区设置
      PanelTheme.swift        两套主题（system / dolmo）
      ClipPanelController.swift  NSPanel 浮窗、键盘事件、光标定位
      ClipPanelView.swift     SwiftUI 列表与搜索
      ClipPanelViewModel.swift   排序、过滤、选中
      ZoomState.swift         缩放/平移状态
      ImagePreviewPanel.swift 悬停预览小面板
      ImageViewer.swift       全屏大图查看器
```

## 图标

应用图标和菜单栏图标是同一套几何（圆形果身 + 右上柳叶）。菜单栏用模板图跟随深浅；应用图标由 `tools/draw_icon.swift` 等比放大上色。重新生成：`./tools/build_icon.sh`。

替换 /Applications 里的 app 后图标有缓存，需要 `lsregister -f` + `killall Dock`。

## 设计迭代

UI 用独立评审子 agent 循环迭代（Lenny's Newsletter 的方法）：`design-review/critic-prompt.md` 是固定评审 prompt，`rN-critique.md` 记录每轮采纳/不采纳。截图体积大不入库，可用 `./build.sh && .build/release/DolmoPaste --snapshot design-review/rN` 自行生成。

## Roadmap

- [ ] 顺序粘贴栈：连续复制多条，按顺序吐出
- [ ] 分割复制：一次复制多行，拆成多条
