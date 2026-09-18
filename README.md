# InputMate

InputMate 是一个轻量的 macOS 菜单栏应用：

- 可自己录制一个鼠标键作为 `Command-C`（复制）
- 可自己录制另一个鼠标键作为 `Command-V`（粘贴）
- 触控板始终使用自然滚动
- 外接鼠标始终使用传统滚动
- 支持登录时自动启动
- 提供原生图形化设置窗口，集中管理权限、侧键、滚动、诊断和登录项

应用不会频繁改写 macOS 的“自然滚动”设置，而是根据每个滚动事件的来源进行归一化。因此鼠标和触控板可以同时连接。

## 构建

需要 macOS 13 或更高版本以及 Apple Command Line Tools：

```sh
./scripts/build-app.sh
open dist/InputMate.app
```

## 打包与安装

生成带有“应用程序”快捷方式的压缩 DMG：

```sh
./scripts/package-dmg.sh
```

产物位于 `dist/InputMate-<version>.dmg`。打开 DMG 后，将 `InputMate.app` 拖到 `Applications` 即可安装。本地开发版使用稳定的 ad-hoc 签名；如果要发给其他人，还应使用 Apple Developer ID 签名并完成 notarization。

构建脚本使用 Objective-C/AppKit 公开系统框架直接编译，不需要下载第三方依赖。产物同时支持 Apple Silicon 和 Intel Mac，并在替换现有应用前完成 plist、严格编译警告与签名校验。

首次启动后，请在“系统设置 → 隐私与安全性”中同时允许 InputMate 的“辅助功能”和“输入监控”权限。

绑定方法：点击菜单栏鼠标图标，选择“录制‘复制’侧键…”或“录制‘粘贴’侧键…”，然后按下想使用的鼠标键。

应用启动后默认只在菜单栏后台运行，登录时不会自动弹出配置窗口。可通过菜单栏鼠标图标中的“打开设置…”显示窗口；应用已在运行时，再次从“应用程序”打开也会显示设置。

滚动后重新打开菜单，“最近滚动”一行会显示 InputMate 判断的设备类型、连续/离散模式、系统自然滚动状态与原始 Y 增量，可用于排查特定鼠标的事件格式。

## 实现说明

- 使用 Core Graphics HID event tap 拦截额外鼠标按键和滚轮事件，并在 HID 不可用时回退到 Session event tap。
- 使用双指手势时序识别触控板，使用连续/离散滚动作为辅助判断。
- 默认侧键编号为 3 和 4，可在菜单栏中使用“录制”功能覆盖。
- 高频事件回调使用内存中的配置快照，避免每个滚轮事件访问偏好设置存储。

## 已知边界

- Magic Mouse 与触控板都会产生连续滚动，因此需要结合手势事件识别。
- 安全输入模式下，macOS 可能禁止全局事件处理。
- 开发构建使用稳定的本地 designated requirement，但第一次从 0.1 版升级后仍应在隐私设置中删除旧 InputMate 权限项，再添加当前 `dist/InputMate.app`。正式发布应使用 Developer ID 签名和公证。
