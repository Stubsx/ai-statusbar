# 图标规范

本项目有两套互不相干的"图标"，规范分开说明：

## 1. App 图标（静态资产）

当前图标为「晴蓝」圆球：透明背景、天蓝水洗色层与白色胶囊眼睛。
`scripts/render-app-icon.swift` 复用 `BallInkDrawing.swift` 的静帧算法，以
1024px 原生分辨率导出，眼睛采用悬浮球正视状态的比例；不包含运行环或计数。

| 路径 | 角色 |
| --- | --- |
| `AppIcon-1024.png` | 源图，1024×1024，所有尺寸的唯一来源 |
| `AppIcon.iconset/` | 从源图导出的全套尺寸（iconutil 的输入） |
| `AppIcon.icns` | 由 iconset 生成，`build.sh` 会复制进 `灵眸.app/Contents/Resources/` |
| `2026-*/` | 设计草稿归档（按日期保留），不参与构建，新草稿继续按日期建目录 |

更新 App 图标的流程：

```bash
# 1. 在仓库根目录运行，生成源图、全套尺寸及 icns
bash scripts/generate-app-icon.sh
# 2. 检查 output/app-icon/preview.png 的浅色/深色与小尺寸预览
# 3. 重新构建验证（构建本身只复制已生成的静态图标）
./AIStatusBar/build.sh && open "AIStatusBar/灵眸.app"
```

注意：`icon_64x64@2x.png` 与 `icon_128x128.png`、`icon_512x512@2x.png` 与
`icon_1024` 尺寸重叠是 iconset 规范要求（不同逻辑尺寸），不是冗余文件。

## 2. 运行时 UI 图标（代码内绘制，不放位图资产）

规范与 ZSpaceMonitor 对齐，核心原则：

1. **一律用 SF Symbol，不用 emoji（🟢🟡⚪️）或文本字符（●、▶）**。
   emoji 和字符的渲染随系统字体漂移，明暗外观下颜色不可控；
   SF Symbol 由 `symbol()`（`AIStatusBar/Sources/main.swift`）程序化着色：
   先画符号做 alpha 蒙版，再 `sourceAtop` 着色，输出 2x Retina 位图，
   `isTemplate = false`。
2. **状态色只有一个映射**：`NSColor.toolStatusColor(_:)`，三处共用
   （菜单栏徽标、下拉菜单、桌面面板），禁止各处硬编码 RGB。

   | 状态 | 颜色 | 含义 |
   | --- | --- | --- |
   | `busy` | `systemGreen` | 工作中 |
   | `idle` | `systemYellow` | 空闲 |
   | `off` | `systemGray` | 未运行 |

   破坏性动作（退出等）用 `systemRed`，与 ZSpaceMonitor 一致。
3. **每个菜单动作行都要有图标**（`NSMenuItem.image`），语义对照：

   | 场景 | SF Symbol |
   | --- | --- |
   | 状态汇总行 | `circle.fill`（状态色） |
   | 进行中任务 | `play.fill`（绿） |
   | 最近任务 | `clock`（次级标签色） |
   | 全部未运行 | `moon.zzz`（灰） |
   | 设置 | `gearshape` |
   | 显示/隐藏卡片 | `rectangle.on.rectangle` |
   | 置顶 | `pin` |
   | 刷新 | `arrow.clockwise` |
   | 退出 | `power`（红） |

   SwiftUI 面板内对应使用 `Image(systemName:)` 同名符号。
4. **菜单栏徽标例外**：`C●2 X●` 这种紧凑字母+圆点徽标是文本排版
   （`badgeTitle`），圆点颜色走同一 `toolStatusColor` 映射；
   它是产品识别设计，不改成单一图标。

## 3. 其他前端的对应规范

- **SwiftBar 文本输出**（`LingmouCollectorCore.renderSwiftBar()`）：
  纯文本协议，菜单栏标题行无法嵌图，emoji（🟢🟡⚪️）是该生态的惯用
  着色手段，保持现状。
- **Übersicht 桌面 widget**（web 渲染）：不用字符 ▶，运行中任务用内联
  SVG 三角形（对齐 `play.fill` 视觉），状态色取 macOS 系统色同款色值
  （`#30d158` / `#ffd60a` / `#636366`）。
