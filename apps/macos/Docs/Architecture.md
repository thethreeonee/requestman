# macOS 架构边界

## 两个客户端

浏览器扩展继续独立构建、发布。macOS 不依赖扩展的 React UI、`chrome.*` API 或页面注入脚本。当前不共享规则执行代码，也不保证两端 JSON 规则互通；将来设计明确版本的交换格式后再增加转换层。

## 组件职责

| 组件 | 职责 | 当前状态 |
| --- | --- | --- |
| Requestman 宿主 App | 应用选择、规则和请求界面、配置、授权交互 | 基础界面；无授权操作 |
| RequestmanCore | 捕获配置、上游路由、捕获服务契约 | 已建立 |
| ApplicationCatalog | 使用 NSWorkspace 读取运行中的应用 | 已建立；只列常规 GUI 应用 |
| CaptureService 实现 | 系统扩展生命周期、IPC、状态和错误传播 | 仅有明确不可用的实现 |
| TransparentProxy 系统扩展 | 按来源筛选 TCP/UDP 流，转交代理引擎 | 待实现 |
| 本地代理引擎 | HTTP/CONNECT、TLS、请求/响应修改、Mock、上游连接 | 待选型与实现 |
| 证书和存储 | 本地 CA、Keychain、信任引导、规则与记录持久化 | 待实现 |

依赖方向：`Features → WorkspaceModel → CaptureService / RequestmanCore`。系统扩展和代理核心通过明确的 IPC 协议连接；不要直接跨进程共享 UI 状态。`CaptureConfiguration` 目前只是 Swift 模块间的数据契约，还不是稳定 IPC 协议。

## 预期流量路径

```text
目标应用 → 来源识别与接管 → 本地 HTTP/HTTPS 代理 → 规则处理
                                               ├─ Mock → 返回目标应用
                                               └─ 上游连接 → Surge 或系统路由 → 服务端
```

先支持 HTTP/1.1、HTTP/2；HTTP/3、WebSocket、自定义 TCP/UDP 等需要各自定义能力边界。接管连接不代表已经能解密或修改协议内容。证书绑定应用不能仅靠安装本地 CA 获得支持。

应用列表中的 Bundle ID 是用户选择键，不能等同于网络流的签名身份。实际接管必须解析签名信息、审计令牌及辅助进程归属，避免误捕获。空选择必须拒绝启动，不能退化为全局捕获。

## Surge 共存

首选显式上游链路：Requestman 做调试修改，Surge 做出口分流。当前 `UpstreamRoute` 只定义两种意图：

- `system`：使用系统现有路由，仍可能经过增强模式；不表示绕过 Surge。
- `httpProxy`：向配置的 HTTP 代理建立连接，HTTPS 使用 CONNECT。UI 中 `127.0.0.1:6152` 只是填写初值，不是自动检测结果。

接入时必须解决：

1. 系统代理开启时，目标 App 可能连接 Surge 的回环代理端口。需要明确该流是否可接管并解析 CONNECT；如果回环流不可接管，提供显式代理接入路径，不能显示假成功。
2. 增强模式可能提供 Fake IP。尽量保留原域名并交给 Surge 解析，不把 Fake IP 当作可直连的公网目标。
3. 排除捕获组件自身和 Surge 出站流量，防止转发循环。代理引擎不能递归遵循指向自己的系统代理。
4. 同一目标域名的双重 MITM 和改写必须有明确处理策略。建议用户在 Surge 中排除该调试域名的 MITM，应用不自动改写其配置。
5. 重建连接后 Surge 可能只识别到 Requestman 进程。必须实测 `PROCESS-NAME` 规则，不能宣称原进程身份必然保留。
6. Surge 未运行、监听地址变化、上游连接失败时报告明确错误；配置了显式上游时不静默切换到其他出口。

## 下一阶段验收

最小闭环：选中一个测试 App → 显示一个真实 HTTPS 请求 → 用本地 JSON Mock → 未命中的请求通过指定 Surge 上游访问服务器。

| 场景 | 需要验证 |
| --- | --- |
| Surge 关闭 | 非目标应用不受影响；测试 App 请求与 Mock 正常 |
| 仅系统代理 | CONNECT 与回环路径；目标 App 归属 |
| 仅增强模式 | Fake IP、DNS、路由、无循环 |
| 系统代理与增强模式同时开启 | 捕获一次、转发一次、连接可恢复 |
| Surge 同时启用目标域名 MITM | 信任链、双重改写和排除行为 |
| Surge 按进程分流 | 重建连接前后规则命中是否变化 |
| 上游退出或端口失效 | 明确报错，不静默绕过 |
| 停止捕获 / 退出 / 扩展失效 | 原连接策略恢复，无残留代理配置 |

以上均为待实现、待实测项目，不是当前能力声明。

## 参考

- [Apple Network Extension 部署要求](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)
- [NETransparentProxyProvider](https://developer.apple.com/documentation/networkextension/netransparentproxyprovider)
- [Surge 增强模式](https://manual.nssurge.com/features/enhanced-mode.html)
- [Surge 进程规则](https://manual.nssurge.com/rules/process.html)
- [mitmproxy macOS 接管实现](https://www.mitmproxy.org/posts/local-capture/macos/)

代理核心尚未选型；采用现有引擎前验证本地接管、上游串联能否组合，并评估嵌入分发与许可证要求。
