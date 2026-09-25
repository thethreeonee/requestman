# macOS 架构边界

## 产品方向与接入顺序

主要场景是辅助 Chrome Web 开发，通过请求出站与响应回站两条流程执行自动修改、动态取值、脚本、辅助请求、Mock 和可选人工断点。完整范围、执行语义建议、模块选型及验收见 [产品与技术设计草案](ProductDesign.md)。当前已接入原生工作区、HTTP/1.1 显式代理和 CONNECT 透传；完整 HTTPS 修改链路仍是待实现设计。

当前通过系统 HTTP/HTTPS 代理或 Chrome 显式代理接入，按应用透明接管作为另一接入适配器，复用代理与流程引擎。显式代理模式不能宣称具备透明接管的应用归属能力；用户点击开始捕获或启动调试 Chrome 时触发系统代理接管，不修改 Surge 配置和证书信任。

## 两个客户端

浏览器扩展继续独立构建、发布。macOS 不依赖扩展的 React UI、`chrome.*` API 或页面注入脚本。当前不共享规则执行代码，也不保证两端 JSON 规则互通；将来设计明确版本的交换格式后再增加转换层。

## 组件职责

| 组件 | 职责 | 当前状态 |
| --- | --- | --- |
| Requestman 宿主 App | 项目、双向流程、全局记录、环境与连接配置 | SwiftUI 界面及配置持久化已接入；运行效果待人工验收 |
| RequestmanCore | 工作区模型、模板与动作、捕获契约、资源边界 | 已实现基础动作与测试 |
| LocalCaptureService | 宿主捕获边界与代理生命周期 | 使用独立显式代理配置；不放宽透明捕获的空选择校验 |
| SystemProxyController | 系统 HTTP/HTTPS 代理接管、原配置保存与恢复 | SystemConfiguration + Authorization Services；设置策略与失败恢复已有替身测试，系统授权待人工验收 |
| TransparentProxy 系统扩展 | 按来源筛选 TCP/UDP 流，转交代理引擎 | 待实现 |
| RequestmanProxy | HTTP/CONNECT、双向修改、Mock、上游连接 | SwiftNIO 实现 HTTP/1.1 与加密隧道；MITM 待实现 |
| WorkflowEngine | 有序双向动作、动态模板、环境快照 | 基础动作已接入；脚本、辅助请求、断点待实现 |
| 存储与证书 | 工作区持久化、全局记录、本地 CA | JSON 配置保存及有界内存记录已实现；数据库、Keychain、CA 待实现 |

依赖方向：`Features → WorkspaceModel → CaptureService / RequestmanCore`。本轮本地代理库运行在宿主进程的独立 NIO 事件循环。未来系统扩展和代理核心需要明确的 IPC 协议，不直接跨进程共享 UI 状态。`CaptureConfiguration` 目前只是 Swift 模块间的数据契约，还不是稳定 IPC 协议。

窗口控件采用 SwiftUI 与 AppKit 的局部桥接：主工具栏切换使用 `NSSegmentedControl`，设置内的环境分栏使用 `NSSplitViewController`，其内容由两个观察同一工作区模型的 `NSHostingController` 承载。设置分栏不安装导航工具栏；不把 `NavigationSplitView` 嵌入设置的 `TabView`。这是 macOS App，不引入 UIKit 或 Mac Catalyst。控件桥接不改变捕获与持久化契约。

请求日志的详情 Inspector 挂在工作区 `NavigationSplitView` 外层，使用系统全高右侧栏，不受列表底部状态栏限制；详情工具栏提供 `sidebar.right` 展开/收起按钮。选中记录后自动展开，手动收起保留选择，未选择记录时按钮禁用；清空或记录淘汰会关闭详情，进入请求日志页仍从未选择状态开始。布局依据 [Apple Inspector 层级说明](https://developer.apple.com/videos/play/wwdc2023/10161/)，实际窗口外观待人工验收。

Chrome 启动由 `WorkspaceModel` 编排：发现已安装的 Chrome → 通过 `CaptureService` 确保监听与系统代理接管 → `ChromeLauncher` 使用 NSWorkspace 和专用配置目录启动浏览器。设置页只触发服务动作，不执行 shell 命令。启动错误在设置页显示，仅回滚本次新建的监听与系统代理。浏览器已启动不等同于已观察到代理流量。

普通捕获与 Chrome 启动共用 `CaptureStartupPreflight`：先校验配置，启用上游时经 `CaptureService.checkUpstream` 调用 `UpstreamProxyProbe`，使用 Network.framework 尝试 TCP 连接，设置 3 秒总时限并支持取消。成功或超时后关闭探测连接，不访问外部测试网站，不验证代理协议、认证或目标可达性。检查失败由 AppKit sheet 提供“关闭上游并启动 / 继续使用上游 / 取消启动”；只有明确选择关闭才修改并保存上游配置。检查与选择都在监听、系统代理接管之前完成；期间禁用重复启动和连接配置编辑，已有监听不重复检查。探测遵循 [NWConnection 状态](https://developer.apple.com/documentation/network/nwconnection/state-swift.enum)，不读取系统 HTTP 代理来建立到上游的连接。

`LocalCaptureService` 先监听再调用 `SystemProxyController` 接管，先恢复系统设置再关闭监听。恢复失败保留监听与恢复文件，并阻止正常退出；UI 同步仍在运行的监听端口。`SystemProxyController` 在独立 actor 中锁定网络偏好会话，按服务 ID 保存原配置后统一 commit/apply。接管当前网络位置中已启用且支持代理协议的服务，临时关闭 PAC、自动发现、SOCKS 和绕过列表；恢复仅覆盖仍与接管值一致的字段组，保留其他工具的新设置。恢复文件写入成功后才能设置代理，恢复 commit/apply 成功后才清空记录。强制退出后的恢复在下次启动进行，没有常驻恢复 helper；新增网络服务或切换网络位置后需重新开始捕获。API 的持久化与运行时应用是两个步骤，见 [Apple SCPreferences 文档](https://developer.apple.com/documentation/systemconfiguration/scpreferences-ft8)。

`RequestmanCore` 已提供 `FlowExecutionRuntime`：不可变计划/环境版本、按需 Body 读取、有界准入与缓冲预算、可批量读取的元数据环形缓冲。它与 UI、数据库和代理框架无关，详细容量、取消与接入契约见 [性能与资源边界](Performance.md)。基础代理在 NIO 事件循环直接执行 metadata/static-body 动作，使用连接准入和写完成后的拉取背压；不把每个网络块转成 Swift Task，也没有把两套准入队列叠加。`FlowExecutionRuntime` 为后续需要完整 Body 的异步动作保留，尚未包裹 NIO 转发。

## 预期流量路径

```text
系统 HTTP/HTTPS 代理 / Chrome 显式代理 → 本地 HTTP/HTTPS 代理 → 请求流程
                                                        ├─ Mock ───────┐
                                                        └─ 上游连接    │
                                                            ↓          │
                                                   Surge 或系统路由    │
                                                            ↓          │
                                                          服务端       │
                                                            ↓          ↓
客户端 ← 本地 HTTP/HTTPS 代理 ← 响应流程 ←────────────── 服务器响应 / Mock
```

当前支持 HTTP/1.1 内容处理及 CONNECT 字节透传。HTTP/2 内容处理、HTTP/3、WebSocket、自定义 TCP/UDP 后续分别定义能力边界。接管连接不代表已经能解密或修改协议内容。证书绑定应用不能仅靠安装本地 CA 获得支持。

系统代理接入只影响遵循 macOS 代理设置的应用，并非全流量透明接管。上游连接使用 NIO socket，不读取指向 Requestman 的系统 HTTP 代理，避免递归；显式配置指向自身的上游仍拒绝，连接完成后再检查解析后的地址。

按应用透明接管模式中，应用列表的 Bundle ID 是用户选择键，不能等同于网络流的签名身份。实际接管必须解析签名信息、审计令牌及辅助进程归属，避免误捕获。空选择必须拒绝启动，不能退化为全局捕获。未来显式代理入口需要独立的配置与校验契约，不通过放宽现有 CaptureConfiguration 的空选择校验实现。

请求流程在主请求发往上游前执行，响应流程在对应内容返回客户端前执行。Mock 跳过主上游请求并进入响应流程；辅助 HTTP 请求独立标记，默认跳过普通流程匹配。暂停、脚本和辅助请求共享执行时间预算，不能保证客户端无限等待。完整 Body 编辑、头部处理与流式透传的边界见产品设计文档。

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

Chrome 最小闭环：显式代理接入 → 修改真实 HTTPS 请求 → 受控服务器确认最终请求 → 修改响应 → Chrome Network 显示最终状态码/Header/Body；本地 JSON Mock 不访问主上游，未命中请求通过指定 Surge 上游访问服务器。

透明接管后续闭环：选中一个测试 App → 按来源捕获 → 复用同一双向流程 → 非目标应用不受影响。以下共存矩阵按接入方式分别验证，涉及应用归属与扩展的项目仅适用于透明接管。

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

本轮代理选用 [SwiftNIO](https://github.com/apple/swift-nio)，使用其 HTTP/1 编解码和 socket/event-loop 实现，不自行解析 HTTP。依赖锁定见 Package.resolved；分发时需要包含 SwiftNIO 及其传递依赖的许可证。CONNECT 回环与上游串联已有集成测试；Chrome/Surge 共存矩阵仍待人工实测。
