# Requestman for macOS

独立的原生 macOS Web 调试工具。以项目组织请求修改，每条修改包含请求、响应两条流程；标题栏通过“请求修改 / 请求日志”切换全局页面，环境管理收纳在设置中。界面依据 [设计稿](Docs/Design/README.md) 实现，浏览器扩展仍独立运行与发布。

## 当前实现

| 模块 | 已实现 |
| --- | --- |
| 原生工作区 | 原生侧栏与步骤 List、Form 编辑及 Inspector 详情；项目/请求修改增删与复制、启停、步骤排序、本地预览 |
| 环境 | 命名变量组增删与编辑、整组切换、固定值与 `{{env.name}}` 模板、`{{$uuid}}`、`{{$timestamp}}` |
| HTTP/1.1 代理 | 回环监听、显式接入、双向流式转发、分块上传、可配置 HTTP 上游、停止关闭连接 |
| 系统代理 | 开始捕获时接管当前网络位置中已启用服务的 HTTP/HTTPS 代理；停止、退出恢复原设置，重启尝试恢复异常退出记录 |
| 请求流程 | 设置/移除 Header、修改方法、切换 HTTP 目标、替换文本 Body、Mock、返回重定向 |
| 响应流程 | 设置/移除 Header、状态码、替换文本 Body、重定向；Mock 同样经过响应流程 |
| HTTPS | CONNECT 加密透传，可串联 HTTP 上游；只记录隧道建立，**尚不能解密和修改 HTTPS** |
| 全局记录 | 项目/环境/结果筛选、搜索、执行步骤、修改前后 Header、耗时/字节数、暂停记录、清空 |
| 配置保存 | 项目/环境/代理配置异步自动保存；退出前刷新保存；环境随请求固定快照 |

还未实现 HTTPS MITM/证书管理、HTTP/2 内容处理、WebSocket 升级、脚本、辅助请求、人工断点、JSON 局部修改、磁盘执行历史和透明应用接管。没有把这些能力做成可点击但不执行的步骤。完整目标见 [产品设计](Docs/ProductDesign.md)。

所有捕获来自真实代理流量，首次启动不插入示例项目和假记录。“开始捕获”先启动本地监听，再通过 macOS 授权接管系统 HTTP/HTTPS 代理；不修改 Surge 配置或证书信任。系统代理只接入遵循该设置的应用，不覆盖自行直连或 UDP 流量；状态栏不推断 Chrome 已连接。

## 手动接入

1. 打开 [Requestman.xcodeproj](Requestman.xcodeproj)，使用共享的 `Requestman` scheme。开发环境要求 Swift 6.2+，部署目标 macOS 14.0。
2. 点击侧栏底部加号，在菜单中选择“添加请求”或“添加项目”。添加请求时使用当前请求所属项目，未选中请求时使用第一个项目，没有项目时自动创建；新请求会被选中并展开所属项目，同时清空搜索。添加项目沿用创建项目及首条请求的流程。配置请求修改，例如 URL 前缀 `http://localhost:3000/`，添加请求 Header 或静态 Mock。匹配采用项目顺序中的首个启用流程，空前缀不匹配；多个匹配流程不叠加执行。
3. 从菜单栏“Requestman → 设置…”（`⌘,`）打开“环境管理”创建环境，填入 `apiKey`、`cookie` 等变量，在步骤中引用 `{{env.apiKey}}`，使用标题栏原生环境下拉框快速切换整组变量。配置停止编辑约 350 ms 后保存并应用；已开始的请求继续使用原快照。
4. 点击“开始捕获”，按 macOS 提示授权修改网络设置。系统 HTTP/HTTPS 代理指向默认 `127.0.0.1:9090`。也可在设置 →“连接”中点击“启动 Chrome 并开始监听”，复用同一接管流程并打开专用 Chrome 调试窗口；其 localhost 请求也经过代理。
5. 打开本地 HTTP 开发页面。请求日志中确认命中的项目、步骤、目标与响应。Chrome Network 的请求仍是浏览器发出的内容；HTTP 响应是代理处理后的结果。
6. 停止捕获或正常退出会先恢复原系统代理，再关闭监听和现有隧道。恢复失败会保留监听，显示错误供重试，并暂缓退出。专用调试 Chrome 仍使用显式代理，停止后应关闭该调试窗口。

上游配置在 Settings 的“连接方式”中，不出现在主工作区。配置了上游时不会失败后静默改走其他出口；不使用 HTTP 上游时仅沿用系统路由，仍可能经过其他网络软件的增强模式。上游认证暂未实现。

启用 HTTP 上游时，两个启动入口都会先检查上游地址的 TCP 连接，最多等待 3 秒。失败后可选择“关闭上游并启动”（关闭并保存上游设置）、“继续使用上游”（保留配置启动）或“取消启动”。选择前不创建监听、不切换系统代理；已有监听时直接复用。该检查不访问外部测试网站，只确认端口可连接，不验证代理认证、协议能力或目标站点可达性。

使用 Surge 时，先启用“使用 HTTP 上游代理”并填写 Surge 的 HTTP 监听地址与端口，再开始捕获。流量路径为“应用 → Requestman → Surge → 服务端”；默认填写值 `127.0.0.1:6152` 不代表已检测到 Surge。监听期间避免让 Surge 重新接管系统代理，否则遵循系统代理的应用可能绕过 Requestman。

接管覆盖当前网络位置中已有且已启用代理协议的网络服务，包括未连线的 Wi-Fi/以太网服务。接管时临时禁用 PAC、自动代理发现和 SOCKS，并清空绕过列表；停止时按字段组恢复原值，保留用户或其他工具在监听期间修改的字段组。切换网络位置或新增服务后，需要停止并重新开始捕获。原配置保存在 `~/Library/Application Support/Requestman/system-proxy-recovery.plist`，仅当前用户可读写。强制退出或崩溃后无法立即恢复，重新打开 Requestman 会尝试恢复；恢复成功前不覆盖旧记录。

Chrome 通过 NSWorkspace 启动，使用 `~/Library/Application Support/Requestman/Chrome/port-<端口>` 下的专用配置，同一端口可复用调试数据。按端口区分配置，避免 Chrome 复用仍指向旧监听端口的进程。启动过程中禁用重复操作；未安装 Chrome、监听失败或启动失败会在设置页显示错误。若本次新建了监听但 Chrome 启动失败，会停止本次监听；原先已经运行的代理保持运行。启动参数依据 Chromium 的 [用户数据目录](https://chromium.googlesource.com/chromium/src/+/HEAD/docs/user_data_dir.md) 和 [代理配置](https://chromium.googlesource.com/chromium/src/+/HEAD/net/docs/proxy.md) 说明。

## 行为与资源边界

- Body 未被替换时以二进制块透传，不收集完整内容、不自动解压或格式化。静态 Body 替换不读取原 Body；转发期间仍会消费原流以完成 HTTP 消息。
- `Content-Length`、传输分块、Host 与逐跳头由代理维护；不能通过 Header 步骤注入矛盾的报文边界。替换 Body 清除原编码与内容校验字段。重定向返回 3xx，内部 URL 改写不向客户端返回 3xx。
- 每条连接处理一个 HTTP 事务，返回 `Connection: close`；尚无连接池。请求有 30 秒总时限，CONNECT 建立后空闲读超时 120 秒。长 SSE / 长下载目前不作为支持目标。
- 活跃连接、预读、Header、步骤、生成内容及记录都有上限；UI 和磁盘保存不阻塞转发。详见 [性能边界](Docs/Performance.md)。
- 记录只保留最近 500 条元数据，不保存 Body，关闭应用即丢失。常见凭据 Header 被隐藏；URL 与自定义 Header 仍应视为调试数据。暂停记录不会停止流程或网络。
- 工作区位于 `~/Library/Application Support/Requestman/workspace.json`，目录权限 0700、文件权限 0600。环境值目前存于这个本地文件，尚未迁移到 Keychain。加载失败时禁用编辑，避免覆盖原文件。

## 工程与验证

宿主通过 `CaptureService` 访问实现；`RequestmanCore` 保存模型、动作与资源契约，`RequestmanProxy` 使用 SwiftNIO 处理真实连接。依赖版本记录在 [Package.resolved](Packages/RequestmanCore/Package.resolved)。

Debug 使用 `ONLY_ACTIVE_ARCH=YES`，使宿主与 Swift Package 都面向当前运行目标的架构；Release 保留 `ONLY_ACTIVE_ARCH=NO`。不要仅让 Debug 宿主额外编译另一架构，否则可能在依赖只有 arm64 模块时出现 x86_64 的 `Unable to resolve module dependency`。工程检查脚本包含此配置校验；独立包的测试和源码类型检查不能替代 Xcode 工程构建验收。

```sh
swift test --package-path apps/macos/Packages/RequestmanCore
python3 apps/macos/Scripts/check-native-sources.py --typecheck
```

当前 56 项测试包含核心资源/取消/模板/匹配测试、本地回环网络集成、上游启动检查与选择分支，以及 7 项系统代理设置与恢复测试。网络集成覆盖真实请求与响应修改、Mock 不访问主上游、分块上传、替换 Body、HEAD、CONNECT 首包及上游串联、错误记录、停止释放端口。上游检查测试覆盖回环连接、关闭连接、失败时限、取消，以及关闭上游/保留上游/取消启动三个分支。系统设置测试使用内存替身，覆盖多服务恢复、外部修改保留、授权拒绝、应用失败重试及损坏恢复文件，不修改测试机器的网络设置。宿主源文件另通过 Swift 6 静态类型检查。

这些检查没有构建、安装或运行 App，也不代表 Chrome 界面验收、HTTPS 解密、Surge 真实共存或性能基准已通过。手动验收重点包括上游不可用时两个启动入口的原生提示和三种选择、系统授权允许/取消、Wi-Fi 与以太网切换、停止与退出恢复原设置、崩溃后重新打开恢复、监听期间外部代理改动，以及原有工作区和 Chrome 接入流程。遵守仓库约束，不使用 Xcode / `xcodebuild` 编译并部署 App 到真机，也不拆分操作绕过此约束。
