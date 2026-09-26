# macOS 架构边界

## 产品方向与接入顺序

主要场景是辅助 Chrome Web 开发，通过请求出站与响应回站两条流程执行自动修改、动态取值、脚本、辅助请求、Mock 和可选人工断点。完整范围、执行语义建议、模块选型及验收见 [产品与技术设计草案](ProductDesign.md)。当前已接入原生工作区、HTTP/1.1 显式代理、HTTPS 解密与未配置证书时的 CONNECT 透传。

当前通过系统 HTTP/HTTPS 代理或 Chromium 浏览器显式代理接入，按应用透明接管作为另一接入适配器，复用代理与流程引擎。主导航栏是唯一启动入口，通用设置决定 `CaptureMode.systemProxy`（全局接管）或 `.browser`（仅启动浏览器）。前者修改系统代理，后者只启动回环监听并带参数打开所选浏览器，不读写当前系统代理设置。显式代理不是按进程过滤；捕获启停不修改 Surge 配置和证书信任。用户主动打开 HTTPS 证书设置时，由独立服务生成、安装 CA 并请求当前用户的 SSL 信任授权。

## 两个客户端

浏览器扩展继续独立构建、发布。macOS 不依赖扩展的 React UI、`chrome.*` API 或页面注入脚本。当前不共享规则执行代码，也不保证两端 JSON 规则互通；将来设计明确版本的交换格式后再增加转换层。

## 组件职责

| 组件 | 职责 | 当前状态 |
| --- | --- | --- |
| Requestman 宿主 App | 项目、双向流程、全局记录、环境与连接配置 | 纯 AppKit 窗口、页面与配置持久化已接入；运行效果待人工验收 |
| RequestmanCore | 工作区模型、模板与动作、捕获契约、资源边界 | 已实现基础动作与测试 |
| LocalCaptureService / LocalProxyCaptureService | 宿主捕获边界与代理生命周期 | 宿主提供恢复记录路径，包内服务持有会话模式；不放宽透明捕获的空选择校验 |
| SystemProxyController | 系统 HTTP/HTTPS 代理接管、原配置保存与恢复 | SystemConfiguration + Authorization Services；设置策略与失败恢复已有替身测试，系统授权待人工验收 |
| TransparentProxy 系统扩展 | 按来源筛选 TCP/UDP 流，转交代理引擎 | 待实现 |
| RequestmanProxy | HTTP/CONNECT、双向修改、Mock、上游连接 | SwiftNIO + NIOSSL 实现 HTTP/1.1、HTTPS 解密与加密透传 |
| WorkflowEngine | 有序双向动作、动态模板、环境快照 | 基础动作与隔离同步脚本已接入；异步脚本、辅助请求、断点待实现 |
| 存储 | 工作区持久化、全局记录 | JSON 配置保存及有界内存记录已实现；数据库待实现 |
| RequestmanCertificates | 本机 CA、钥匙串安装、SSL 信任与校验 | 原生引导和可重试流程已实现；系统授权与浏览器实测待验收 |

证书配置入口位于设置 → 通用的“HTTPS 证书”分组，本地代理、上游代理和协议支持也统一放在通用页。证书引导由 `WorkspaceModel.certificateSetup` 持有 `CertificateSetupModel`，经 `CertificateService` 访问独立的 `LocalCertificateService` actor；界面控制器不直接读写 Security。只在用户点击“设置证书…”后串行检查、生成、安装、授权和复核，已完成步骤可复用，取消不会自动重弹授权。私钥使用不可导出的文件型钥匙串键，由登录钥匙串锁和 ACL 保护；此选择兼容当前无专用 Keychain entitlement 的 macOS 宿主，公开 CA 安装到浏览器读取的默认钥匙串。证书编码和签名使用 [Apple swift-certificates](https://github.com/apple/swift-certificates)，不手写 X.509 或把私钥写到磁盘。当前用户信任只指定 SSL policy，授权由 `SecTrustSettingsSetTrustSettings` 系统面板执行；验证使用短期内存测试叶证书、主机名及系统 SSL 信任链，不设置自定义 anchors、不关闭证书校验。过期、损坏或密钥不匹配时报告错误并保留原材料，不静默轮换。证书与捕获服务共享同一个 actor。新 CONNECT 连接经 `TLSCertificateProviding` 获取短期站点证书；未完成信任时保持透传，已信任时升级到 NIOSSL 服务端并复用 HTTP 流程，按 CONNECT authority 校验内层 Host 与目标。CA 密钥不导出，P-256 站点密钥仅在内存中使用；SAN 支持 DNS/IPv4/IPv6，证书最多有效 7 天、不超过 CA 到期，缓存上限 128 个。已有透传连接需重建，历史记录不回填。

`ProxyTLS` 使用 Apple NIOSSL 处理 TLS，出站验证异步交给 macOS `SecTrust`，同时检查真实目标的主机名和系统/用户信任；关闭网络证书补取避免系统代理递归，不关闭证书校验。仅 internal 测试构造器允许内存测试锚点。CONNECT 建立、升级后等待内层请求、每个 HTTP 事务分别限时 30 秒，上游 TLS 握手计入该 HTTP 事务；升级时先安装 TLS 处理器，再释放 CONNECT decoder 缓冲的首包数据。解密记录完整保留 URL、方法、双向 Header 和旁路采集的 Body；网络线程不等待完整内容、不解压。回环测试不安装或信任本机 CA。

依赖方向：`Features → WorkspaceModel → CaptureService / RequestmanCore`。本轮本地代理库运行在宿主进程的独立 NIO 事件循环。未来系统扩展和代理核心需要明确的 IPC 协议，不直接跨进程共享 UI 状态。`CaptureConfiguration` 目前只是 Swift 模块间的数据契约，还不是稳定 IPC 协议。

CA 材料和实际信任结果使用最多 5 秒的固定期限缓存，命中不会续期；状态刷新、生成、安装、信任操作先失效旧缓存，应用重新激活也刷新状态。刷新失败不能沿用旧的可信结果。站点 TLS 服务端 context 按叶证书 DER 缓存最多 128 个，复用前仍须经过证书提供方的信任检查；出站共用 TLS context，但每次新连接的目标与信任验证独立执行。

证书授权弹窗只允许发生在用户主动打开的配置流程。`CertificateSetupModel.prepareForStartup` 每个模型生命周期最多尝试一次静默授权迁移，后续激活只刷新状态；迁移经 `LocalCertificateService.migrateAuthorization` 先检查当前能力，仅对授权错误修复现有 CA 的 ACL，禁止 UI，不生成、安装或修改信任，成功必须通过静默复核。系统拒绝静默迁移时保留手动设置入口，不因激活或 HTTPS 请求重复迁移。`CertificateKeychainInteraction` 在同步互斥作用域内管理文件型钥匙串的进程级交互开关，配置操作允许授权，状态检查及 CONNECT 签发禁止授权，退出时恢复原状态；作用域内不挂起、不执行网络 I/O。`KeychainSigningKey` 从公开 CA 证书取得公钥，直接调用 `SecKeyCreateSignature`，拒绝私钥序列化；加载时通过实际签名验证密钥匹配，避免旧 X509 SecKey 包装器在读取已有 CA 时导出公钥。配置阶段为当前应用添加仅签名的 ACL，并在允许系统交互的作用域实际签名一次，让系统处理 App 签名身份变更后的 partition 授权，保留既有权限和 CA；新建密钥的默认权限只信任创建应用。最终配置复核必须在禁止弹窗的条件下通过，才显示已配置；访问被拒绝时状态失效并引导用户回到“设置证书…”，运行期不自动授权。稳定的应用签名身份仍是跨版本复用授权的前提，真实系统授权与重启行为待验收。

`CertificateSetupModel.canRegenerate` 仅在私钥缺失或显式恢复中断时提供“重新生成证书”。`LocalCertificateService.regenerate` 再次检查密钥；若已恢复则复用，访问错误不能当作缺失。确认缺失后按完整 DER 匹配移除旧证书及其当前用户信任，再将公开文件移入废纸篓，最后复用生成、安装、信任与静默复核流程。清理公开文件发生在新建私钥之前，因此生成后写入失败可通过已有的孤立私钥恢复路径重试，不重复生成密钥；多个证书或不匹配材料保持原状。

HTTP/1.1 顺序请求复用下游连接，每条下游最多保留一个同目标、同出口的上游连接，HTTPS 同时复用 TLS 会话。上游主动关闭后，下次请求重新建连；不重试已发送请求。每个事务完成后清空规则匹配、Body 采集器和内存租约，保留独立记录；闲置 30 秒关闭且不生成虚假失败记录，停止监听关闭在用和闲置连接。仍限制最多 256 个下游连接，不支持流水线和跨客户端连接池。 浏览器预连接或请求完成后的空闲 TLS 连接收到 `uncleanShutdown`（未发送 `close_notify`）时只关闭连接，不新增失败 CONNECT；真实握手中断和进行中的请求仍记录失败与不完整 Body。TLS 错误保留 NIOSSL 枚举及底层 BoringSSL 原因，避免 NSError 桥接只显示数字错误码。

主窗口由 `WorkspaceWindowController` 创建 `NSWindow`，直接将 `WorkspaceSplitController` 作为 contentViewController；窗口与分栏尺寸全部由 AppKit 管理。项目侧栏、主内容和 Inspector 使用保留的 `NSViewController`，内容约束到各栏的系统 safe area。两侧分别使用 `NSSplitViewItem(sidebarWithViewController:)` 与 `NSSplitViewItem(inspectorWithViewController:)`，启用 `allowsFullHeightLayout` 与窗口 `.fullSizeContentView`，由系统提供贯穿窗口高度的侧栏材质。左栏范围 260–400 pt，初始 320 pt；主内容最小 420 pt；右栏范围 400–760 pt，初始 520 pt。之后由分栏保留用户宽度，拖动分隔线不改变工作区外框。`ObservedViewController` 用 `withObservationTracking` 注册一次性依赖并在变更后重新注册，在主线程更新既有控件；不轮询模型，不因每次输入重建编辑器。窗口工具栏使用独立 `WorkspaceToolbarSnapshot` 跳过相同状态的重复更新。

主窗口仅安装一条 `.unified` 原生 `NSToolbar`，工作区切换直接使用 `NSSegmentedControl`。`WorkspaceSettingsWindowController` 持有独立设置窗口，使用 `ToolbarSectionControl` 原生分段控件切换“通用 / 环境管理”，保留 `.large` 尺寸与系统胶囊形状。两个窗口隐藏标题文字，设置内容固定 800 × 540 pt，切换页面不改变窗口大小。通用页在同一个 `NSScrollView` 中用系统 `NSBox` 分组，收纳启动方式、浏览器、本地代理、上游代理、协议支持和 HTTPS 证书。浏览器使用带应用图标的 `NSPopUpButton`；设置内的环境列表与编辑页采用 `NSSplitViewController`、`NSTableView` 和 AppKit 字段。设置不另装第二条导航栏。

请求日志使用原生 `NSTableView`，按“时间 / 状态码 / 请求 / 命中的规则 / 项目 / 环境 / 耗时”展示。行高 56 pt，主文字 13 pt。请求列将有同色边框和浅背景的方法标签与 URL 单行居中，仅失败时显示第二行说明；状态码按 1xx/2xx/3xx/4xx–5xx 分别使用系统蓝/绿/橙/红色。规则列以次级颜色展示类型、主颜色展示执行时捕获的工作流名称，最多两行，更多通过原生 +N 按钮查看；项目列只显示项目。列宽支持原生表头拖动，按稳定列标识保存到 `UserDefaults`（`requestLog.columnWidths.v1`），重新打开页面或 App 时恢复。通过 `NSTableColumn.width` 的变化在原生鼠标跟踪过程中同步调整相邻列及表格边界，松手通知仅保存最终列宽，窗口或详情栏改变可用宽度时按保存比例适配并保留最小宽度；记录刷新不重置列宽，自动适配不覆盖偏好。保持无横向滚动、禁止列重排；耗时固定在最右列，标题与数值右对齐。长文本截断并提供完整提示。

`RequestFilterControls` 在列表顶部提供单行暂停/清空、资源类型和筛选 Popover。搜索使用 `WorkspaceSplitController` 管理的原生 `NSSearchToolbarItem`，紧邻标题栏启动按钮左侧，仅请求日志页显示；通过 `WorkspaceToolbarSnapshot` 同步 `history.filter.search`，支持输入、清除、Popover 重置与切换页签保留条件。窄内容区将资源分段控件收为下拉菜单。`ExecutionHistoryModel.filter` 持有 `CaptureRecordFilter`，Core 统一处理搜索、MIME/扩展名分类、项目/环境/结果/方法以及原始/修改后请求 Header 条件。Header 使用全部/任一组合和三值逻辑，缺失证据不因反向匹配产生假命中。`WorkflowEngine.apply` 每步成功后回调，代理记录有界 `CaptureMatchedRule` 快照；未执行、禁用和失败步骤不混入成功规则。具体语义及验收见 [请求日志筛选设计](Design/request-log-filters.md)。

请求日志页使用原生 `NSToolbarItem` 作为唯一详情开关，创建时显式连接分栏控制器的 `toggleInspector` 动作；左栏按钮同样连接 `toggleSidebar`。这些工具栏项使用应用自己的标识，保持 `view = nil`，由 AppKit 显示 SF Symbol 和默认按钮外观，不依赖当前焦点转发动作。详情按钮在展开和收起后均保留，未选中有效记录时禁用；请求修改页复用该项展开步骤详情，详情标题与选择状态随页面切换。`NSTrackingSeparatorToolbarItem` 跟随右侧分栏边界，其后仅在展开时显示左对齐的“请求详情”标题；标题使用原生 `NSTextField`，字号取 `NSFont.preferredFont(forTextStyle: .title2).pointSize`，字重为 `.semibold`，工具栏项 `isBordered = false`，不额外添加玻璃背景。`RequestInspectorViewController` 不另建工具栏，`RequestsViewController` 不提供第二个详情按钮。选中记录自动展开，手动收起保留选择及 Tab 状态；原生 `isCollapsed` 是可见性的唯一来源，KVO 将其同步到详情的 `isPresented`，关闭隐藏内容及 Popover 的交互而保留宿主。清空或记录淘汰关闭详情，进入请求日志页仍从未选择状态开始。整个窗口与详情均不设底部状态栏；详情上方保留方向、数量、“仅显示变更”和内容提示，数据区域延伸至底部操作区上方。控件层依据 [Apple AppKit Inspector 与工具栏说明](https://developer.apple.com/videos/play/wwdc2023/10054/)，此次原生窗口布局仍待真实 App 运行验收。

捕获按钮使用原生 `NSButton` 的 `.imageOnly` 布局，显示绿色播放或红色停止图标；可见标题保持为空，当前启动方式与状态说明通过 `toolTip` 和辅助功能标签提供。状态刷新不向 `title` 写入文本，以免 AppKit 自动切换为图文重叠布局。

`check-workspace-sidebar.py` 编译实际工作区原生壳与模型、内容替身，在不显示的 `NSWindow` 中回归分栏布局、工具栏和状态同步，包括捕获按钮在浏览器名称、启动/停止及禁用状态变化后的宽度、图标布局与动作，以及纯 AppKit 窗口下在 1100/1440/1800 pt 窗口中调整左右分隔线后，工作区仍贴住窗口左右边缘、窗口大小保持不变和可见栏最小宽度。它与完整 App 的外观、鼠标交互和真实数据验收分别报告，不能以隐藏窗口回归代替视觉验收。

`check-inspector-performance.py` 进一步使用真实请求表格和详情组件、75 条替身记录，在隐藏窗口反复选择、展开、缩放和收起详情，检查空闲 CPU 与相同快照下工具栏图像的稳定性。页面控制器保留既有视图层级与明确尺寸约束，工具栏快照相同则跳过控件赋值，避免重复布局更新；隐藏窗口测试仍不能替代实际 App 的性能验收。

详情内容复用 `ToolbarSectionControl`，直接使用 `NSSegmentedControl` 展示请求头、请求体、响应头、响应体四项；macOS 26+ 用控件自身的 `borderShape = .capsule` 配置胶囊形状，macOS 27+ 设 `.tabs` 语义，继续使用 `.automatic` 分段样式；主工作区和设置保留其既有布局。内容 Tab 使用 `.fillEqually` 均分可用宽度，macOS 26+ 采用原生 `.extraLarge` 尺寸，旧系统使用 `.large`，不再以 `.fit` 紧凑居中；同一行右侧放置原生复制按钮。该行使用固有高度；分段与复制按钮均配置垂直 hugging/compression 优先级，复制桥接实现 `sizeThatFits`，防止其抢占内容区高度并将 Tab 推到侧栏中间。当前可见 Payload 通过 Preference 提供复制内容及其 Tab、版本，切换中或数据不可用时禁用复制，防止复制上一页内容。形状与绘制均由 AppKit 提供，不添加 `NSGlassEffectView` 包装。

显示模式“修改前 / 修改后 / 修改对比”使用展开右栏顶部标题工具栏中的原生 `NSSegmentedControl`，紧邻更多按钮左侧；采用 `.automatic` 分段样式、`.large` 尺寸、macOS 26+ 的原生 `.capsule` 形状及 macOS 27+ 的 `.tabs` 语义。Inspector 级状态统一持有显示模式，默认修改后；四个内容 Tab 共用该值，收起重开或选择不同记录时保留。各 `RequestPayloadView` 独立保留搜索、树展开、滚动和树形/原始数据格式，不再各自保存版本选择。

`RequestPayloadControls` 底部只保留搜索和 JSON 原始数据切换，横向 12 pt、纵向 10 pt 留白与左栏一致。底部格式切换与 Tab 右侧复制使用原生 `NSButton`，macOS 26+ 采用控件自身的 `.glass` bezel 样式，分别为 `.capsule` 与 `.circle` 形状，不叠加玻璃容器；旧系统采用对应的原生圆角或圆形按钮。`NSSearchField` 使用 `.large` 系统搜索外观，不额外添加玻璃包装。请求体、响应体的 JSON 格式在“原始数据”与“树形视图”之间切换，不改变当前显示模式。`RequestInspectorView` 固定摘要、独立查询参数入口与条件规则入口，查询参数来自原始/最终 URL，不混入 Body；`RequestDataOutline` 通过 `NSOutlineView` 提供 Header 和 JSON 字段树。原始数据使用只读 `NSTextView`，保留文本缩进、换行和字段顺序，不重新格式化；非 JSON 直接显示文本或十六进制，不提供无效切换。Payload、Outline 和 Source 不再设置独立白背景，由系统 Inspector 背景贯穿；字段仍仅用系统色的低透明度背景表达变更。原生按钮在行悬停时以 0.15 秒淡入淡出并复制值或完整子树，遵循减少动态效果设置；提供右键与键盘替代。`RequestInspectionData` 在后台构造差异和节点，隐藏/不完整数据不产生推测性差异。系统侧栏建议宽度 520 pt，可在 400–760 pt 调整。外观与鼠标交互仍待 App 运行验收。

`CaptureBodyCollector` 随流量完整记录原始请求、发出请求、服务器响应和最终响应，`CaptureBodySnapshot` 共享不可变内容，不设置单快照尺寸或全局 Body 预算。URL 和 Header 完整保留，所有凭据与环境变量直接显示原值。记录包括完整、未完成、未采集和不可用状态，Mock 无上游原始响应。写入失败不会被后续结束标记成功掩盖。`RequestBodyDecoding` 只对完整快照在详情后台任务中使用系统 zlib 解码 gzip / deflate，不设置解压输出尺寸和编码层数上限；JSON 树不设置应用层字节数、层数和节点数上限。Body 预览不落盘，详见 [性能边界](Performance.md) 与 [请求详情设计](Design/request-inspector.md)。

详情顶部以原生 `NSButton` 承载单行中间省略的 URL，保留原字号与系统全文悬停提示。点击通过 `NSPopover` 展示完整已记录文本，文本可选择、折行并在超长时滚动，复制按钮调用 `RequestClipboard.copy(record.url)`；`urlWasTruncated` 时显示不完整提示并禁用完整复制。侧栏隐藏或切换记录时关闭 URL Popover。

更多菜单由工作区的 `NSMenuToolbarItem` 承载，设 `isBordered = true` 使用系统按钮外观，位于展开侧栏工具栏的收起按钮左侧，折叠时隐藏，不再占用 URL 摘要。菜单依次提供“复制完整 URL / 复制原始请求为 cURL / 复制修改后请求为 cURL”，不完整时禁用相应项并提供原因。`RequestCURL` 使用原始或发送快照导出，正文保持采集的实体字节，不复用解压或格式化后的显示文本；传输分帧与长度交给 curl 重建。URL、Header 或 Body 不完整时不生成误导性的完整请求，Header 原值直接用于导出。命令只在用户点击复制时构造，不自动执行请求。

`RequestDataNode.jsonStringValue` 保存可检查字符串的实际值，与显示摘要、JSON 引号及复制载荷分开；Header 按当前显示版本的完整性决定是否提供该值。行悬停时通过后台任务调用 `RequestInspectionData.stringJSONPreview`，复用既有 JSON 解析限制与节点生成；成功后用原生按钮打开 `NSPopover`，其原生 `NSViewController` 内容仍是 `RequestDataOutline`。解析不替换原节点，嵌套字符串按需逐层检查，不预先递归解码所有字符串。

统一启动由 `WorkspaceModel.toggleCapture` 编排。全局模式通过 `CaptureService.start(..., mode: .systemProxy)` 监听并接管系统代理，不启动浏览器；浏览器模式先发现并校验所选应用，再通过 `.browser` 仅启动监听，最后由 `BrowserLauncher` 使用 NSWorkspace 和代理参数启动应用。浏览器启动失败关闭本次监听并在主窗口提示；没有浏览器也不影响全局模式启动。偏好保存在 UserDefaults，默认维持全局接管；实际会话固定 `activeMode` 和浏览器快照，运行中修改偏好不改变当前流量范围。停止与退出依据实际会话执行。

`ChromiumBrowserCatalog` 合并系统注册的 HTTP/HTTPS 应用与系统、用户 Applications 目录，在后台检查网页声明及 Chromium 框架资源，兼容带版本的 Framework 目录，排除更新缓存、废纸篓与 App Translocation 副本，按 Bundle ID 去重并优先使用系统推荐安装，不依赖浏览器名称白名单。启动前重新校验应用，专用数据目录按 Bundle ID 与端口隔离，保留既有 Google Chrome 目录。发现或启动成功不等同于已观察到代理流量，各 Chromium 衍生浏览器对启动参数的支持仍待逐一运行验收。

两种启动方式共用 `CaptureStartupPreflight`：先校验配置，启用上游时经 `CaptureService.checkUpstream` 调用 `UpstreamProxyProbe`，使用 Network.framework 尝试 TCP 连接，设置 3 秒总时限并支持取消。成功或超时后关闭探测连接，不访问外部测试网站，不验证代理协议、认证或目标可达性。检查失败由 AppKit sheet 提供“关闭上游并启动 / 继续使用上游 / 取消启动”；只有明确选择关闭才修改并保存上游配置。检查与选择都在监听、系统代理接管之前完成；期间禁用重复启动和连接配置编辑。探测遵循 [NWConnection 状态](https://developer.apple.com/documentation/network/nwconnection/state-swift.enum)，不读取系统 HTTP 代理来建立到上游的连接。

连接配置停止输入约 350 ms 后由 `WorkspaceModel` 串行应用，期间与启停、浏览器启动和退出互斥；防抖取消不取消已经开始的系统设置事务。上游配置经 `LocalProxyServer.updateConfiguration` 更新，新连接读取独立配置快照，现有请求与隧道保持原路由。端口变更通过 `CaptureService.restart` 自动先停止再启动，显式传递当前 `activeMode`，失败回滚也保留模式。停止恢复失败时保留原监听，新配置启动失败且没有必须保留的监听时尝试恢复旧配置。浏览器会话切换端口后，自动为当前会话浏览器打开新端口调试窗口，不使用可能已改动的下次启动偏好；旧窗口不自动关闭。设置页显示错误并同步实际监听状态。

`LocalProxyCaptureService` 的全局会话先监听再调用 `SystemProxyController` 接管，先恢复系统设置再关闭监听；浏览器会话的正常启动、重配、回滚和停止不调用系统代理服务。全局恢复失败保留监听与恢复文件，并阻止正常退出；UI 同步仍在运行的监听端口。上次异常退出的系统代理恢复由 App 载入时独立执行，失败时记录待恢复状态，阻止新浏览器会话沿用残留全局代理；下次启动动作先重试旧会话恢复，退出也会重试。`SystemProxyController` 在独立 actor 中锁定网络偏好会话，按服务 ID 保存原配置后统一 commit/apply。接管当前网络位置中已启用且支持代理协议的服务，临时关闭 PAC、自动发现、SOCKS 和绕过列表；恢复仅覆盖仍与接管值一致的字段组，保留其他工具的新设置。恢复文件写入成功后才能设置代理，恢复 commit/apply 成功后才清空记录。没有常驻恢复 helper；新增网络服务或切换网络位置后需重新开始全局接管。API 的持久化与运行时应用是两个步骤，见 [Apple SCPreferences 文档](https://developer.apple.com/documentation/systemconfiguration/scpreferences-ft8)。

`RequestmanCore` 已提供 `FlowExecutionRuntime`：不可变计划/环境版本、按需 Body 读取、有界准入、可批量读取的元数据环形缓冲。它与 UI、数据库和代理框架无关，详细容量、取消与接入契约见 [性能与资源边界](Performance.md)。基础代理在 NIO 事件循环直接执行 metadata/static-body 动作，使用连接准入和写完成后的拉取背压；不把每个网络块转成 Swift Task，也没有把两套准入队列叠加。`FlowExecutionRuntime` 为后续需要完整 Body 的异步动作保留，尚未包裹 NIO 转发。

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

当前支持 HTTP/1.1 内容处理、HTTPS 解密以及未配置证书时的 CONNECT 字节透传。HTTP/2 内容处理、HTTP/3、WebSocket、自定义 TCP/UDP 后续分别定义能力边界。TLS 两端只协商 HTTP/1.1；上游可直接 TLS 或经 HTTP 代理 CONNECT 后 TLS。证书绑定应用不能仅靠安装本地 CA 获得支持。

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

## 请求修改配置与同步脚本（2026-09-26）

匹配配置改为 URL / Host 与四类规则，旧前缀按转义正则迁移，工作区保存版本为 2。步骤详情接入同一个窗口级 Inspector，Header 使用插件候选列表的原生可编辑组合框。同步 JavaScript 通过可终止的独立进程执行，具有脚本的阶段在后台读取完整 Body、解码文本后执行；未带脚本的阶段保留 NIO 流式路径。取消与事务截止时间沿脚本流程传递；输入/输出没有新增载荷尺寸上限。完整 API、并发和时限、验收范围见[请求修改配置](Design/request-modification.md)。

## AppKit 界面迁移（2026-09-26）

`RequestmanEntry` 在处理脚本 worker 参数后创建 `NSApplication`。`WorkspaceAppDelegate` 安装系统菜单、持有主窗口和设置窗口，负责启动加载、前台证书状态刷新、后台保存及退出前恢复代理。所有界面与测试替身移除 SwiftUI 和 Hosting 桥接，核心 Observation 模型、代理、证书及脚本契约保留。`check-native-sources.py` 同时检查工程源引用及 AppKit-only 约束，阻止重新引入声明式桥接。工作区、请求详情、筛选、Header、规则编辑和设置使用隐藏 AppKit 窗口回归；完整 App 的系统外观、真实鼠标体验与浏览器网络验收仍单独报告。
