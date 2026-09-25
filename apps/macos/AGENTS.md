# macOS 开发约定

- 先读 [README.md](README.md) 与 [Docs/Architecture.md](Docs/Architecture.md)。当前已有 HTTP/1.1 显式代理和 CONNECT 透传；不能将静态 UI 检查或回环测试表述为 Chrome 实测、HTTPS 解密或性能验收通过。
- 原生 UI 使用 SwiftUI，必要的系统集成使用 AppKit。采用 Swift 6 并发检查；UI 状态保持 `@MainActor`，按功能拆分视图。
- 与 UI 无关的配置和服务契约放在 `Packages/RequestmanCore`。宿主状态通过 `CaptureService` 访问捕获实现，不在视图中直接操作 Network Extension、代理或证书。
- `Extensions/TransparentProxy` 目前只有实现边界说明。引入真实 target 时同步补齐 provider、签名、entitlements、嵌入、安装/卸载与 IPC，不创建看似可用但吞掉流量的占位 provider。
- 与 Surge 共存时区分系统代理、增强模式、MITM；保留来源信息、域名和避免循环的要求见架构文档。不得把系统路由称为保证绕过 Surge 的直连。
- 开始捕获或启动调试 Chrome 是接管系统 HTTP/HTTPS 代理的明确操作；先监听再接管、先恢复再停止。恢复失败保留监听并阻止退出，异常退出记录在下次启动时恢复。不得自动修改 Surge 配置或证书信任。
- 核心逻辑变更运行相关 Swift package 测试；工程调整检查源文件引用、共享 scheme 和配置。构建、静态检查与真实网络行为分别报告。
- 遵守上级规则：禁止通过 Xcode / `xcodebuild` 编译 App 并部署真机运行测试，不通过拆分命令绕过。

## 原生控件约束

- 所有 UI 组件必须使用苹果提供的原生控件实现，保留系统标准外观、交互和可访问性行为。优先使用 SwiftUI 的系统控件；SwiftUI 无法满足时桥接对应的 AppKit 控件，不自行绘制或拼装仿制控件。
- 不要为了玻璃而玻璃。玻璃效果应由原生控件和当前系统样式自然提供；不得仅为追求玻璃外观，额外叠加 `NSGlassEffectView`、`glassEffect`、模糊、材质、描边或阴影，或替换原生控件的背景和造型。使用系统材质 API 包装控件，不等于使用原生控件的默认外观。
- 分段切换、按钮、菜单、列表、表格、侧栏和工具栏均使用对应的系统组件。自定义 View 只负责业务内容与必要的布局组合，不另造控件皮肤。即使设计稿或历史要求提到“玻璃”，也应先采用原生控件的系统表现，不把玻璃效果作为独立目标。
- 用户确认的原生控件样式通过苹果公开属性配置，例如 `NSSegmentedControl.borderShape = .capsule`；这不属于自绘或额外玻璃包装。清理自定义装饰时保留已确认的原生样式配置，不能一并移除。
