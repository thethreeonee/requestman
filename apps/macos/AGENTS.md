# macOS 开发约定

- 先读 [README.md](README.md) 与 [Docs/Architecture.md](Docs/Architecture.md)。当前已有 HTTP/1.1 显式代理和 CONNECT 透传；不能将静态 UI 检查或回环测试表述为 Chrome 实测、HTTPS 解密或性能验收通过。
- 原生 UI 使用 SwiftUI，必要的系统集成使用 AppKit。采用 Swift 6 并发检查；UI 状态保持 `@MainActor`，按功能拆分视图。
- 与 UI 无关的配置和服务契约放在 `Packages/RequestmanCore`。宿主状态通过 `CaptureService` 访问捕获实现，不在视图中直接操作 Network Extension、代理或证书。
- `Extensions/TransparentProxy` 目前只有实现边界说明。引入真实 target 时同步补齐 provider、签名、entitlements、嵌入、安装/卸载与 IPC，不创建看似可用但吞掉流量的占位 provider。
- 与 Surge 共存时区分系统代理、增强模式、MITM；保留来源信息、域名和避免循环的要求见架构文档。不得把系统路由称为保证绕过 Surge 的直连。
- 开始捕获或启动调试 Chrome 是接管系统 HTTP/HTTPS 代理的明确操作；先监听再接管、先恢复再停止。恢复失败保留监听并阻止退出，异常退出记录在下次启动时恢复。不得自动修改 Surge 配置或证书信任。
- 核心逻辑变更运行相关 Swift package 测试；工程调整检查源文件引用、共享 scheme 和配置。构建、静态检查与真实网络行为分别报告。
- 遵守上级规则：禁止通过 Xcode / `xcodebuild` 编译 App 并部署真机运行测试，不通过拆分命令绕过。
