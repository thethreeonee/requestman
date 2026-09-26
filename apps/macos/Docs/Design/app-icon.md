# Requestman App 图标

2026-09-26：采用橙白双向通路与深灰至黑色渐变背景。前景图案与背景分开保存于 [AppIcon.icon](../../Requestman/Resources/AppIcon.icon)，不在输入素材中预裁圆角，也不添加外围透明边距。系统负责不同 macOS 版本的轮廓与材质。

![Icon Composer 默认外观导出](app-icon-preview.png)

## 资源与接入

- `AppIcon.icon/icon.json`：保留最终在 Icon Composer 中调整的背景渐变、0.8 倍前景缩放、0.3 透光与 0.5 自然投影配置。
- [透明前景 PNG](../../Requestman/Resources/AppIcon.icon/Assets/exec-6b9b83e0-3a48-4b83-9380-4e7041f03aeb.png)：内置 ImageGen 从本次选定设计提取并清理，保留导入 Icon Composer 时的文件名。
- `Configuration/Base.xcconfig`：`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`。
- 工程以 `folder.iconcomposer.icon` 引用文档，并加入 Requestman 的 Resources 阶段。构建工具要求 Xcode 26+，最低部署版本保持 macOS 14。

编辑时在 Icon Composer 中打开 `.icon`，保持背景与前景分层。透明 PNG 只包含箭头，背景使用文档的渐变填充；不要把这里的圆角预览 PNG 替换为前景素材。旧系统图标通过资源编译自动生成，无需同时维护一个同名 `.appiconset`。

前景提取提示词要点：保留已选定的两条箭头及其位置和比例，移除背景与烘焙的阴影、高光，橙色请求箭头向右、白色响应箭头向左，其余区域透明。生成方式为内置 ImageGen，最终材质与轮廓由 Icon Composer 渲染。

## 验证

`python3 apps/macos/Scripts/check-native-sources.py` 检查文档、图层文件、图标名与资源阶段引用。独立调用 Apple `ictool` 可导出预览；独立 `actool` 以 `--platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon` 编译该资源，检查生成的 `AppIcon.icns`、`Assets.car` 与图标 Info.plist 键。

Agent 验证了图标渲染、独立资源编译及工程静态配置，没有构建、安装或启动完整 App。随后只读检查用户已构建并运行的 App：包内图标、Info.plist、LaunchServices 注册信息、NSWorkspace 与运行中进程的图标读取均正确。刷新应用注册并重启 Dock 后，用户确认 Dock 图标正常显示；Requestman 原进程保持运行。Finder 和实际 macOS 14/15 的安装显示尚未验收。

参考：[Apple Icon Composer 制作与接入说明](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)。
