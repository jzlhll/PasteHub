# PasteHub

PasteHub 是一个 macOS 状态栏剪贴板工具：自动记录复制内容，通过浮动面板快速检索，并支持一键回填到原应用输入框。

![App截图](Images/screenshot-20260318-094525.png)

## 主要功能

- **剪贴板历史**：自动监听文本、图片、文件三类内容
- **历史 + 常用片段双模式**：支持在同一面板内切换浏览与操作
- **快速检索**：支持搜索、类型筛选（全部/文本/图片/文件）、标签筛选
- **紧凑模式面板**：支持显示密度（宽松/均衡/紧凑）、面板位置与面板大小
- **全局快捷键**：支持分别设置「显示/隐藏面板」「截图 / 取色」
- **截图与取色**：默认 `Option + Shift + A` 启动，支持放大镜取色、单屏框选、六种标注、保存 PNG 与复制图片
- **键盘快速操作**：支持方向键选中、回车激活、`Cmd + 数字/字母` 快速选择
- **自动回填**：点击条目后先复制，再尝试切回原应用执行粘贴（需辅助功能权限）
- **标签体系**：历史条目与常用片段都可编辑标签
- **分词选择**：文本条目可进入分词选择后再回填
- **排除应用**：可配置不记录指定应用的剪贴板内容
- **开机自启**：通过 `SMAppService` 注册 Login Item

## 运行要求

- 使用 Xcode 打开并运行 `PasteHub.xcodeproj`
- 当前工程 `MACOSX_DEPLOYMENT_TARGET` 为 `26.2`

## 快速开始

1. 打开 `PasteHub.xcodeproj`
2. 选择 `PasteHub` Scheme
3. Build & Run
4. 首次运行后在菜单栏可看到应用图标
5. 按默认快捷键 `Cmd+Shift+V` 呼出面板

## 使用 Command Line Tools 编译

Apple Silicon Mac 可使用新版 Command Line Tools（Swift 6.2 或更新版本、macOS SDK 26.2 或更新版本）编译，无需安装完整 Xcode：

首次配置本机固定签名：

1. 在 macOS「钥匙串访问 → 证书助理 → 创建证书」中创建 `PasteHub Local Signing`，身份类型选择「自签名根」，证书类型选择「代码签名」。证书及对应私钥保存在登录钥匙串中。
2. 如需调整信任，仅为该证书的「代码签名」用途设置信任，其他用途保持默认。该证书用于本机开发，不代表 Apple Developer ID 或公证发布身份。
3. 绑定一次证书：

```bash
python3 scripts/build_macos.py --configure-signing "PasteHub Local Signing"
```

该命令将证书的准确 SHA-1 指纹和 Bundle ID 写入已忽略的 `.local-signing.json`；配置文件不含私钥。证书和私钥保留在钥匙串中，后续构建复用同一身份，不重新生成证书。首次签名时如系统提示 `/usr/bin/codesign` 访问此私钥，可选择「始终允许」，供后续构建复用。

正常编译：

```bash
python3 scripts/build_macos.py --resources-from /Applications/PasteHub.app
```

产物为 `build/PasteHub.app`。构建前检查固定证书是否可用于代码签名，打包后校验签名证书和稳定的签名身份；证书缺失、类型错误或不可用时直接报错，不退回临时签名。

独立 Command Line Tools 不提供 `actool`，因此打包时沿用已有 PasteHub 应用的资源目录（包含 `Assets.car` 和应用图标）。若安装了包含 `actool` 的 Xcode，则直接编译仓库资源。

默认使用本机签名配置中的 Bundle ID（本项目为 `top.yayalu.PasteHub`），可通过 `--bundle-id` 显式指定。首次从临时签名切换到固定证书后，需重新授予屏幕录制和辅助功能权限；以后保持同一证书、Bundle ID 和安装路径，避免因每次编译的二进制哈希变化导致授权失配。迁移电脑时需迁移原证书及私钥，不能只复制 `.local-signing.json`。

## 使用说明

- 复制任意文本/图片/文件后，内容会自动进入历史
- 面板支持搜索、类型筛选和标签筛选
- 单击历史卡片会执行“复制并回填”
- 历史卡片支持：重新复制、编辑标签、删除、添加到常用片段（文本）
- 切换到“常用片段”模式可新建/编辑/删除片段并快速使用

### 截图与取色

- 按 `Option + Shift + A` 或菜单栏「截图 / 取色」开始，按 `Esc` 取消。
- 移动十字指针查看 180 × 180、3 倍放大的放大镜、当前屏幕的物理像素坐标和色值；按 `Shift` 切换 HEX / RGB，按 `Command + C` 复制色值并退出。
- 拖动鼠标左键框选区域；未选择标注工具时可移动选区，拖动八个控制点调整大小，选区外重新拖动可重新框选。
- 选区下方工具栏支持矩形、椭圆、画笔、直线、箭头、马赛克；前五种共用三档线宽与七种颜色。再次点击当前工具可退出标注模式。
- 马赛克通过拖动矩形区域添加；撤销按钮或 `Command + Z` 撤销最近一次标注。
- 下载按钮选择目录保存 PNG；取消保存返回编辑。双击已选截图区域、点击确认按钮、按 `Enter` 或框选后的 `Command + C` 将图片复制到剪贴板并退出截图。
- 当前支持在任意一个显示器内截图；文字、滚动截图与跨屏框选见 [实现列表](docs/screenshot-todo.md)。

### 面板内键盘操作

- 方向键：移动当前选中项
- 回车：激活当前选中项
- `Cmd + 1~0 / A~Z`：按可见顺序快速选择并激活
- 直接输入字符：自动进入搜索

## 设置页说明

- **通用**
  - 历史最大保留条数
  - 开机自动启动
  - 面板模式与布局（紧凑模式、密度、位置、大小、默认弹出方向）
- **快捷键**
  - 录制和修改全局快捷键
  - 查看辅助功能权限状态、路径信息和诊断入口
- **排除应用**
  - 从当前运行应用中快速加入排除名单
- **关于**
  - 版本信息与项目链接

## 权限说明

- **辅助功能权限（Accessibility）**
  - 用于自动切回目标应用并执行粘贴
  - 未授权时，剪贴板记录与手动复制仍可正常使用
  - 可在设置页的“辅助功能权限诊断”中刷新状态并跳转系统设置

- **屏幕录制权限（Screen Recording）**
  - 截图和取色首次使用时请求授权，不采集音频
  - 设置页「快捷键 → 截图权限」可查看状态并跳转系统设置
  - 授权后如仍无法截图，请重启 PasteHub；签名、Bundle ID 或安装路径变化后可能需要重新授权
  - 截图本身无需辅助功能或输入监控权限；保存通过系统文件窗口选择目录

## 数据存储

应用数据默认保存在：

`~/Library/Application Support/PasteHub/`

主要文件：

- `history.json`：历史记录
- `snippets.json`：常用片段
- `Images/`：图片剪贴板缓存

## 常见问题

### 应用闪退或提示无法打开

请使用上面的构建命令重新生成应用并替换原安装版本。构建脚本会设置可执行权限并使用已绑定的固定证书签名；重新使用 `codesign --sign -` 会恢复为临时身份，导致现有隐私授权再次失配。

## 项目结构

```text
PasteHub/
├── PasteHubApp.swift              # 应用入口
├── AppDelegate.swift              # 状态栏、浮窗、全局快捷键
├── Models/
│   ├── ClipboardItem.swift        # 剪贴板条目模型
│   └── SnippetItem.swift          # 片段模型
├── Services/
│   ├── ClipboardMonitor.swift     # 剪贴板轮询
│   ├── ClipboardStore.swift       # 存储与持久化
│   ├── PasteToAppService.swift    # 自动回填
│   └── SettingsManager.swift      # 偏好设置管理
└── Views/
    ├── ClipboardListView.swift    # 主面板 UI
    ├── CompactPanelLayout.swift   # 紧凑面板布局
    ├── FloatingPanel.swift        # 浮动面板窗口
    └── SettingsView.swift         # 设置窗口
```

## License

MIT
