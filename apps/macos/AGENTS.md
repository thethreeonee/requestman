# macOS 开发约定

- 先读 [README.md](README.md) 与 [Docs/Architecture.md](Docs/Architecture.md)。当前是宿主 App 骨架，不能将 UI 配置或单元测试通过表述为捕获已可用。
- 原生 UI 使用 SwiftUI，必要的系统集成使用 AppKit。采用 Swift 6 并发检查；UI 状态保持 `@MainActor`，按功能拆分视图。
- 与 UI 无关的配置和服务契约放在 `Packages/RequestmanCore`。宿主状态通过 `CaptureService` 访问捕获实现，不在视图中直接操作 Network Extension、代理或证书。
- `Extensions/TransparentProxy` 目前只有实现边界说明。引入真实 target 时同步补齐 provider、签名、entitlements、嵌入、安装/卸载与 IPC，不创建看似可用但吞掉流量的占位 provider。
- 与 Surge 共存时区分系统代理、增强模式、MITM；保留来源信息、域名和避免循环的要求见架构文档。不得把系统路由称为保证绕过 Surge 的直连。
- 不自动修改用户的 Surge 配置、系统代理或证书信任。后续产品实现必须通过明确的用户操作触发这些系统变更。
- 核心逻辑变更运行相关 Swift package 测试；工程调整检查源文件引用、共享 scheme 和配置。构建、静态检查与真实网络行为分别报告。
- 遵守上级规则：禁止通过 Xcode / `xcodebuild` 编译 App 并部署真机运行测试，不通过拆分命令绕过。
