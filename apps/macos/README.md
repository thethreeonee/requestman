# Requestman for macOS

独立的原生 macOS 应用骨架。目标是选择应用后修改 HTTP/HTTPS 请求、响应或返回 Mock，并允许把真实请求交给 Surge 等上游代理。

## 当前能力

| 已实现 | 尚未实现 |
| --- | --- |
| SwiftUI 主窗口、侧栏与 Settings 场景 | Network Extension 安装、授权、启停与 IPC |
| 列出正在运行的前台类型应用，按应用标识多选 | 辅助进程识别、真实流量接管 |
| 系统路由 / 显式 HTTP 上游代理配置草稿 | CONNECT 转发、TLS 解密、证书管理 |
| 独立核心模块、配置校验与单元测试 | 请求记录、规则编辑/执行、Mock、配置持久化 |

界面中的请求和规则页是空状态。配置仅保留在本次运行内存中；刷新应用列表会移除已退出应用的选择。捕获服务明确返回“尚未接入”，不会产生演示流量、修改系统代理或安装证书。

## 工程入口

打开 [Requestman.xcodeproj](Requestman.xcodeproj)，选择共享的 `Requestman` scheme。要求 Xcode 26 或更新版本（Swift 6.2+），部署目标 macOS 14.0。

工程只依赖本地 [RequestmanCore](Packages/RequestmanCore/Package.swift)，无第三方 Swift 包。当前只有宿主 App target；透明代理扩展尚未创建、嵌入或启用。后续实现实际捕获时再配置签名团队、唯一 Bundle ID 和相关 entitlements。

基本版本和 Bundle ID 在 [Base.xcconfig](Configuration/Base.xcconfig) 中维护，macOS 版本独立于浏览器扩展版本。`com.requestman.macos` 是开发占位标识，分发前需替换成自己的标识。

## 目录

```text
macos/
├── Requestman.xcodeproj/         # 宿主 App 工程与共享 scheme
├── Configuration/               # 部署目标、版本、签名基础配置
├── Requestman/
│   ├── App/                     # 入口、依赖装配和窗口共享状态
│   ├── Features/                # 应用选择、请求、规则、连接配置
│   └── Infrastructure/          # AppKit 应用枚举、捕获服务适配
├── Packages/RequestmanCore/      # 不依赖 UI 的配置与服务契约
├── Extensions/TransparentProxy/ # 后续系统扩展的实现边界
└── Docs/Architecture.md         # 流量路径、Surge 共存与验收计划
```

## 验证

在仓库根目录运行核心模块测试：

```sh
swift test --package-path apps/macos/Packages/RequestmanCore
```

测试验证空选择不会变成全局捕获、代理地址和端口校验，以及上游路由序列化。它们不验证网络接管或 Surge 兼容性。浏览器扩展继续使用根目录的 `npm test` 和 `npm run build`，不构建 macOS App。

遵守仓库验证约束，不通过 Xcode / `xcodebuild` 编译并部署 App 到真机运行测试，也不拆分命令绕过此约束。
