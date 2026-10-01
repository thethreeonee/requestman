# macOS 架构边界

当前模块与执行契约见 [捕获与规则执行架构](EngineArchitecture.md)：AppKit MVC → CaptureEngine → 事务协调、规则匹配与修改执行；每种步骤由独立 Processor 实现。

## 产品方向与接入顺序

主要场景是辅助 Chrome Web 开发，通过请求出站与响应回站两条流程执行自动修改、动态取值、脚本、辅助请求、Mock 和可选人工断点。完整范围、执行语义建议、模块选型及验收见 [产品与技术设计草案](ProductDesign.md)。当前已接入原生工作区、HTTP/1.1 显式代理、HTTP/2 同协议解密转发、HTTPS 解密与未配置证书时的 CONNECT 透传。

当前通过系统 HTTP/HTTPS 代理或 Chromium 浏览器显式代理接入，按应用透明接管作为另一接入适配器，复用代理与流程引擎。主导航栏是唯一启动入口，通用设置决定 `CaptureMode.systemProxy`（全局接管）、`.browser`（仅启动浏览器）或 `.proxyOnly`（仅启动代理）。前者修改系统代理，浏览器模式带参数打开所选浏览器，仅启动代理模式等待手动接入，两者不读写当前系统代理设置。默认监听回环，局域网开关可将任一模式的监听范围扩展至 IPv4 所有接口。显式代理不是按进程过滤；捕获启停不修改 Surge 配置和证书信任。用户主动打开 HTTPS 证书设置时，由独立服务生成、安装 CA 并请求当前用户的 SSL 信任授权。

## 两个客户端

浏览器扩展继续独立构建、发布。macOS 不依赖扩展的 React UI、`chrome.*` API 或页面注入脚本。当前不共享规则执行代码，也不保证两端 JSON 规则互通；将来设计明确版本的交换格式后再增加转换层。

## 组件职责

| 组件 | 职责 | 当前状态 |
| --- | --- | --- |
| Requestman 宿主 App | 规则组、双向流程、全局记录、环境与连接配置 | 纯 AppKit 窗口、页面与配置持久化已接入；运行效果待人工验收 |
| RequestmanCore | 工作区模型、模板与动作、捕获契约、资源边界 | 已实现基础动作与测试 |
| CaptureEngine / CaptureSession | 捕获会话、代理重配与恢复 | 实现 CaptureService；旧 LocalProxyCaptureService 保留兼容别名 |
| SystemProxyController | 系统 HTTP/HTTPS 代理接管、原配置保存与恢复 | SystemConfiguration + Authorization Services；设置策略与失败恢复已有替身测试，系统授权待人工验收 |
| TransparentProxy 系统扩展 | 按来源筛选 TCP/UDP 流，转交代理引擎 | 待实现 |
| RequestmanProxy | HTTP/CONNECT、双向修改、Mock、上游连接 | SwiftNIO + NIOHTTP2 + NIOSSL 实现 HTTP/1.1、HTTP/2、HTTPS 解密与加密透传 |
| RuleMatchingEngine | 规则选择与条件诊断 | 真实捕获和匹配测试共用 |
| ModificationExecutionEngine / StepProcessor | 有序双向修改、每步原子提交、执行 trace | 模板与脚本运行时独立；WorkflowEngine 仅保留兼容委托 |
| TransactionCoordinator | 固定匹配、环境、计划与取消上下文 | 网络传输通过协调器调用执行引擎 |
| 存储 | 工作区持久化、全局记录 | JSON 配置保存及有界内存记录已实现；数据库待实现 |
| RequestmanCertificates | 本机 CA、钥匙串安装、SSL 信任与校验 | 原生引导和可重试流程已实现；系统授权与浏览器实测待验收 |

证书配置入口位于设置 → 通用的“HTTPS 证书”分组，本地代理、上游代理和协议支持也统一放在通用页。证书引导由 `WorkspaceModel.certificateSetup` 持有 `CertificateSetupModel`，经 `CertificateService` 访问独立的 `LocalCertificateService` actor；界面控制器不直接读写 Security。只在用户点击“设置证书…”后串行检查、生成、安装、授权和复核，已完成步骤可复用，取消不会自动重弹授权。私钥使用不可导出的文件型钥匙串键，由登录钥匙串锁和 ACL 保护；此选择兼容当前无专用 Keychain entitlement 的 macOS 宿主，公开 CA 安装到浏览器读取的默认钥匙串。证书编码和签名使用 [Apple swift-certificates](https://github.com/apple/swift-certificates)，不手写 X.509 或把私钥写到磁盘。当前用户信任只指定 SSL policy，授权由 `SecTrustSettingsSetTrustSettings` 系统面板执行；验证使用短期内存测试叶证书、主机名及系统 SSL 信任链，不设置自定义 anchors、不关闭证书校验。过期、损坏或密钥不匹配时报告错误并保留原材料，不静默轮换。证书与捕获服务共享同一个 actor。新 CONNECT 连接经 `TLSCertificateProviding` 获取短期站点证书；未完成信任时保持透传，已信任时升级到 NIOSSL 服务端并复用 HTTP 流程，按 CONNECT authority 校验内层 Host 与目标。CA 密钥不导出，P-256 站点密钥仅在内存中使用；SAN 支持 DNS/IPv4/IPv6，证书最多有效 7 天、不超过 CA 到期，缓存上限 128 个。已有透传连接需重建，历史记录不回填。

`ProxyTLS` 使用 Apple NIOSSL 处理 TLS，出站验证异步交给 macOS `SecTrust`，同时检查真实目标的主机名和系统/用户信任；关闭网络证书补取避免系统代理递归，不关闭证书校验。仅 internal 测试构造器允许内存测试锚点。CONNECT 建立、升级后等待内层请求分别限时 30 秒；HTTP 请求头收到后取消等待计时器，事务不设总时限；解密目标先读取并保留 ClientHello；客户端同时提供 h2 与 http/1.1 时，先完成上游 TLS 协商，再向客户端提供同一协议，首个同目标请求复用该上游连接。安装 TLS 处理器后重放首包；单协议客户端保持严格同协议路径。解密记录完整保留 URL、方法、双向 Header 和旁路采集的 Body；网络线程不等待完整内容、不解压。回环测试不安装或信任本机 CA。

依赖方向：`Features → WorkspaceModel → CaptureService / RequestmanCore`。`AppComposition` 统一创建并注入服务；工作区模型不再自行创建证书和捕获实现。本轮本地代理库运行在宿主进程的独立 NIO 事件循环。未来系统扩展和代理核心需要明确的 IPC 协议，不直接跨进程共享 UI 状态。`CaptureConfiguration` 目前只是 Swift 模块间的数据契约，还不是稳定 IPC 协议。

CA 材料和实际信任结果使用最多 5 秒的固定期限缓存，命中不会续期；状态刷新、生成、安装、信任操作先失效旧缓存，应用重新激活也刷新状态。刷新失败不能沿用旧的可信结果。站点 TLS 服务端 context 按叶证书 DER 与协议列表缓存最多 128 个，复用前仍须经过证书提供方的信任检查；出站共用 TLS context，但每次新连接的目标与信任验证独立执行。

证书授权弹窗只允许发生在用户主动打开的配置流程。`CertificateSetupModel.prepareForStartup` 在启动和后续激活时均只调用禁止交互的状态检查，不尝试修改私钥 ACL；授权失效只显示手动设置入口。`LocalCertificateService.migrateAuthorization(allowingUI: false)` 遇到授权错误直接返回，不调用 ACL 修复；只有用户主动配置时才允许修复现有 CA 的签名权限，成功必须通过静默复核。`CertificateKeychainInteraction` 在同步互斥作用域内管理文件型钥匙串的进程级交互开关，配置操作允许授权，状态检查及 CONNECT 签发禁止授权，退出时恢复原状态；作用域内不挂起、不执行网络 I/O。`KeychainSigningKey` 从公开 CA 证书取得公钥，直接调用 `SecKeyCreateSignature`，拒绝私钥序列化；加载时通过实际签名验证密钥匹配，避免旧 X509 SecKey 包装器在读取已有 CA 时导出公钥。配置阶段为当前应用添加仅签名的 ACL，并在允许系统交互的作用域实际签名一次，让系统处理 App 签名身份变更后的 partition 授权，保留既有权限和 CA；新建密钥的默认权限只信任创建应用。最终配置复核必须在禁止弹窗的条件下通过，才显示已配置；访问被拒绝时状态失效并引导用户回到“设置证书…”，运行期不自动授权。稳定的应用签名身份仍是跨版本复用授权的前提，真实系统授权与重启行为待验收。

`CertificateSetupModel.canRegenerate` 仅在私钥缺失或显式恢复中断时提供“重新生成证书”。`LocalCertificateService.regenerate` 再次检查密钥；若已恢复则复用，访问错误不能当作缺失。确认缺失后按完整 DER 匹配移除旧证书及其当前用户信任，再将公开文件移入废纸篓，最后复用生成、安装、信任与静默复核流程。清理公开文件发生在新建私钥之前，因此生成后写入失败可通过已有的孤立私钥恢复路径重试，不重复生成密钥；多个证书或不匹配材料保持原状。

HTTP/1.1 顺序请求复用下游连接，每条下游最多保留一个同目标、同出口的上游连接，HTTPS 同时复用 TLS 会话。上游主动关闭后，下次请求重新建连；不重试已发送请求。每个事务完成后清空规则匹配、Body 采集器和内存租约，保留独立记录；闲置 30 秒关闭且不生成虚假失败记录，停止监听关闭在用和闲置连接。仍限制最多 256 个下游连接，不支持流水线和跨客户端连接池。 浏览器预连接或请求完成后的空闲 TLS 连接收到 `uncleanShutdown`（未发送 `close_notify`）时只关闭连接，不新增失败 CONNECT；真实握手中断和进行中的请求仍记录失败与不完整 Body。TLS 错误保留 NIOSSL 枚举及底层 BoringSSL 原因，避免 NSError 桥接只显示数字错误码。

主窗口和独立日志窗口分别由 `WorkspaceWindowController` 创建 `NSWindow`，直接将各自固定为 `.rules` / `.requests` 的 `WorkspaceSplitController` 作为 contentViewController；两个窗口共享 `WorkspaceModel` 与 `ExecutionHistoryModel`，保留各自的分栏、详情状态和窗口位置。日志窗口延迟创建并复用，关闭不停止捕获或清空记录；`WorkspaceModel.selection` 作为打开目标窗口的导航请求，经 App delegate 唤起对应窗口，菜单命令按当前 key window 分发，新建规则先唤起主窗口；窗口与分栏尺寸全部由 AppKit 管理。规则组侧栏、主内容和 Inspector 使用保留的 `NSViewController`，交互内容约束到各栏的系统 safe area；macOS 26+ 请求日志的滚动视图延伸到主栏顶部，由系统自动为标题栏和筛选附件留出内容 inset。规则编辑页同样延伸到标题栏背后，并铺满到底部预览附件栏下方；`RulesViewController` 持有底部原生附件，`FlowEditorViewController` 将预览按钮放入附件内容视图，切换规则时替换内容，无规则时隐藏附件。顶部沿用工具栏默认滚动边缘，底部在 macOS 26.1+ 使用 `.soft`；系统内容 inset 保持首尾字段可达。两侧均使用 `NSSplitViewItem(sidebarWithViewController:)`，启用 `allowsFullHeightLayout` 与窗口 `.fullSizeContentView`，由系统提供贯穿窗口高度的侧栏材质。右侧工具栏使用自定义标识的原生 `NSTrackingSeparatorToolbarItem` 明确跟踪第二条分隔线，避免系统预留 Inspector 标识按角色定位。左右工具栏按钮分别直接切换对应分栏的 `isCollapsed`，通过原生 animator 保留动画，不依赖按角色查找分栏的系统 toggle 实现。左栏范围 260–400 pt，初始 320 pt；主内容最小 420 pt；右栏范围 400–760 pt，初始 520 pt。之后由分栏保留用户宽度，拖动分隔线不改变工作区外框。`ObservedViewController` 用 `withObservationTracking` 注册一次性依赖并在变更后重新注册，在主线程更新既有控件；不轮询模型，不因每次输入重建编辑器。窗口工具栏使用独立 `WorkspaceToolbarSnapshot` 跳过相同状态的重复更新。

规则组树使用 `ProjectOutlineView` 原生选择与展开事件，`RulesSidebarCell` 分别约束箭头后的图标、名称、数量和固定操作栏，文件夹与规则同为 30 pt，名称对齐到同一竖线。底部恢复左加号、右搜索的原有布局。单击选择、双击文件夹整行展开收起；双击使用原生 `doubleAction`；展开按钮与行增删统一由 AppKit 管理；双击经原生 animator 执行展开收起，减少动态效果时直接切换，不再叠加行快照和箭头旋转。数据刷新复用已有节点对象，保留展开状态。步骤列表复用未变更的卡片并保留 `NSBox` 自有内容视图，切换规则时停止旧编辑器观察。`ProjectIconMenu` 以原生 palette 菜单组成六列图标网格，仅展示预览并保留辅助功能名称。`ProjectSidebarRowView` 仅为用户指定的悬停反馈增加浅灰装饰层，用 `CABasicAnimation` 动画 `opacity`（移入 120 ms、移出 160 ms）；model layer 保存终值、presentation layer 用于中途反转，选中、移除与窗口失焦时清理反馈，颜色随有效外观更新。选择、焦点、展开箭头和右键菜单继续由 AppKit 提供。设计与验收范围见 [规则组侧栏](Design/project-sidebar.md)。

请求修改和日志窗口各安装一条 `.unified` 原生 `NSToolbar`，移除请求修改 / 请求日志分段切换。两者分别使用 `Requestman.RulesToolbar` 与 `Requestman.RequestLogsToolbar` 标识；AppKit 会在同标识工具栏之间同步条目和显示状态，即使关闭 `autosavesConfiguration` 也会同步，因此不同窗口布局不能共用标识。`WorkspaceSettingsWindowController` 持有独立设置窗口，使用 `ToolbarSectionControl` 原生分段控件切换“通用 / 环境管理”，保留 `.large` 尺寸与系统胶囊形状。各窗口隐藏标题文字，设置内容固定 800 × 540 pt，切换页面不改变窗口大小。通用页在同一个 `NSScrollView` 中用系统 `NSBox` 分组，收纳启动方式、浏览器、本地代理、上游代理、协议支持和 HTTPS 证书。浏览器使用带应用图标的 `NSPopUpButton`；设置内的环境列表与编辑页采用 `NSSplitViewController`、`NSTableView` 和 AppKit 字段。设置不另装第二条导航栏。

请求日志使用原生 `NSTableView`，列、列内行与行内内容由显示选项配置；默认请求列首行包含状态码、方法和 URL，规则组与规则分别放在规则列的两行。主文字 13 pt，单条记录行高按各列实际分配宽度下的内容度量高度取最大值，至少 56 pt；空行收起后，每个单元格的可见行组仍整体垂直居中。行内只读内容默认使用原生 `NSTextField`，显式 `.roundedRectangleTag`、`.capsule` 与设备来源的 `DeviceSourceButton(usesGlass: false)` 共用原生 `.accessoryBarAction` 按钮样式；macOS 26+ 分别通过 `.roundedRectangle`、`.capsule` 选择圆角矩形与胶囊形状，旧系统沿用同一种原生默认形状。两种呈现使用一致的内边距与文字颜色，仅圆角形状不同。方法与状态码默认配置系统语义色和必要字体；列表方法文本的默认字体与系统语义色和详情的 `RequestMethodLabel`（`NSTextField`）一致，状态码按 1xx/2xx/3xx/4xx–5xx 分别使用系统蓝/绿/橙/红色。规则按捕获的工作流 ID 展示当前名称，改名同步刷新、删除后回退到捕获名称；同一工作流的多个执行步骤不计作多条命中。列顺序支持原生表头拖动并保存，列宽按稳定列标识保存到 `UserDefaults`（`requestLog.columnWidths.v1`），重新打开页面或 App 时恢复。通过 `NSTableColumn.width` 的变化在原生鼠标跟踪过程中同步调整相邻列及表格边界，松手通知仅保存最终列宽，窗口或详情栏改变可用宽度时按保存比例适配并保留最小宽度；记录刷新不重置列宽，自动适配不覆盖偏好。长文本省略时提供完整提示。完整配置、字段提取与搜索契约见下文[请求日志显示选项](#请求日志显示选项)。

macOS 26+ 主内容栏启用 `allowsFullHeightLayout`，请求日志筛选栏与暂停/丢弃状态使用 `NSSplitViewItemAccessoryViewController` 顶部附件；macOS 26.1+ 指定 `.soft` 滚动边缘样式。原生 `NSScrollView` 自动避让附件和标题栏，表头保持在筛选栏下方，滚动内容延伸到两层顶部栏背后；附件仅在独立日志窗口挂载；主窗口保持规则编辑布局，重开日志窗口保留附件和筛选条件。macOS 14/15 保留内联筛选栏。

`RequestFilterControls` 在列表顶部提供暂停/清空、资源类型和表格上方展开的筛选表单，常规宽度单行显示，窄窗口将全部类型分段独立放在第二行。搜索使用 `WorkspaceSplitController` 管理的原生 `NSSearchToolbarItem`，位于主内容区标题栏右侧，仅请求日志页显示；通过 `WorkspaceToolbarSnapshot` 同步 `history.filter.search`，支持输入、清除、表单重置与切换页签保留条件。九项资源类型以原生胶囊分段控件平铺，macOS 26+ 采用 `.extraLarge`、旧系统采用 `.large`，直接按固有尺寸布局，两侧按钮匹配其原生高度；frame 与 bounds 保持相同尺寸，不缩放文字；每段增加 16 pt 横向留白，始终保留完整自然宽度；筛选入口使用 `line.3.horizontal.decrease` 原生玻璃圆形按钮，不显示“更多”或类型下拉菜单。请求行右键“Mock 当前请求”冻结点击时的完整 `CaptureRecord`，交给 `WorkspaceModel.addMockWorkflow(from:)` 在后台通过 `CapturedMockWorkflow` 和既有正文解码器生成规则。匹配原始方法与完整 URL，请求阶段预填原始方法、URL、Body 和 Header；生成的 Header 操作统一为 `.modify`，只修改已有同名项，不生成添加、覆盖、删除项或静态 Mock。有完整上游响应时，响应阶段从 `originalStatus`、`receivedBody` 和 `receivedHeaders` 依次预填状态码、Body、Header，缺少完整原始响应则留空；创建后插入首个命中规则组的规则首位并跳转选中。原始请求完整性检查在菜单和生成器两层执行，不依赖响应成功或完整；详细数据与不可用边界见 [macOS README](../README.md#从日志创建-mock)。`ModificationStep.literalValues` 缺省继续解析模板，捕获生成步骤设为字面值；`bodyEncoding` 缺省文本，二进制使用 Base64，执行时解码为 `HTTPMessageDraft.replacementBodyData`；未解码的原始压缩正文同时保存 `bodyContentEncoding`，文本 Body 步骤发送 Base64 原始实体字节时恢复该编码，使 Header 的“修改”不会因编码已被清除而跳过。代理以 `replacementBytes` 统一发送文本与二进制，长度按字节计算，脚本编辑正文会清除旧二进制替换。`ExecutionHistoryModel.filter` 持有 `CaptureRecordFilter`，Core 统一处理搜索、MIME/扩展名分类、最终响应状态码、原始 URL 包含、原始域名精确匹配、规则组/环境/结果/方法以及原始/修改后请求 Header 条件。`CaptureFilterGroup` 递归组合普通条件和子组，每组独立选择全部／任一；URL、域名、方法与状态码用空格／逗号分隔多个值，前导减号排除。Header 每条独立选择来源并保留原文值，组间共享三值逻辑，缺失证据不因反向匹配产生假命中。筛选表单随顶部附件高度展开，超过上限内部滚动；收起不重置条件，输入更新保持编辑器。`ModificationExecutionEngine.execute` 每步成功后回调，代理记录有界 `CaptureMatchedRule` 快照；未执行、禁用和失败步骤不混入成功规则。具体语义及验收见 [请求日志筛选设计](Design/request-log-filters.md)。

请求日志页使用原生 `NSToolbarItem` 作为工具栏详情开关，创建时显式连接分栏控制器的 `toggleDetailsPane` 动作，再由其调用 `toggleInspector`；左栏按钮同样连接 `toggleSidebar`。这些工具栏项使用应用自己的标识，保持 `view = nil`，由 AppKit 显示 SF Symbol 和默认按钮外观，不依赖当前焦点转发动作。详情按钮在展开和收起后均保留；工具栏通过 `NSToolbarItemValidation` 显式校验，避免系统 Inspector 动作按分栏角色判断可用性。已展开时始终允许收起，收起且未选中有效记录时禁用；请求修改页复用该项展开步骤详情，两个窗口各自保留详情标题与选择状态。右侧 `NSTrackingSeparatorToolbarItem` 仅在右栏展开时安装并跟随实际分栏边界，收起后移除，避免按钮左侧残留竖线；其后仅在展开时显示左对齐的“请求详情”标题；标题使用原生 `NSTextField`，字号取 `NSFont.preferredFont(forTextStyle: .title2).pointSize`，字重为 `.semibold`，工具栏项 `isBordered = false`，不额外添加玻璃背景。`RequestInspectorViewController` 不另建工具栏，`RequestsViewController` 不提供第二个详情按钮。选中新记录自动展开，再次点击当前记录通过表格原生 action 和当前窗口响应链切换详情；`RecordsTableView` 在鼠标按下时记录是否已选中，避免新选择被误判成重复点击。`WorkspaceSplitController` 先同步待处理的选择快照，再应用显式开关，避免异步观察重新展开；键盘选择和程序定位继续沿用自动展开，空白点击与右键菜单不触发开关。手动收起保留选择及 Tab 状态；原生 `isCollapsed` 是可见性的唯一来源，KVO 将其同步到详情的 `isPresented`，关闭隐藏内容及 Popover 的交互而保留宿主。清空或记录淘汰关闭详情，首次打开日志窗口且未选择记录时保持详情收起；重新打开保留原选择。整个窗口与详情均不设底部状态栏；详情上方保留方向、数量、“仅显示变更”和内容提示，数据区域延伸至底部操作区上方。控件层依据 [Apple AppKit Inspector 与工具栏说明](https://developer.apple.com/videos/play/wwdc2023/10054/)，此次原生窗口布局仍待真实 App 运行验收。

环境选择位于主窗口左侧栏工具栏内，顺序为侧栏开关、环境选择、侧栏跟踪分隔线；环境按钮宽度为 90–140 pt，长名称截断。`eyeglasses` 眼镜按钮位于主内容区右上角，右侧栏收起时通过原生工具栏间隔与右侧按钮分组隔开，展开后仍保留在主内容区、实际分栏边界左侧；它与 ⌘2 打开或唤起独立日志窗口，⌘1 唤起请求修改主窗口；日志详情跳转规则和 Mock 创建同样唤起主窗口，打开日志文件和重放结果定位到日志窗口。环境切换快捷键仅在主窗口可用；请求日志通过筛选条件按环境查看记录。捕获按钮位于主内容区工具栏左端，移除居中标识和前置弹性空白。捕获按钮使用原生 `NSButton` 的 `.imageOnly` 布局，显示绿色播放或红色停止图标；可见标题保持为空，当前启动方式与状态说明通过 `toolTip` 和辅助功能标签提供。状态刷新不向 `title` 写入文本，以免 AppKit 自动切换为图文重叠布局。

`check-workspace-sidebar.py` 编译实际工作区原生壳与模型、内容替身，在不显示的 `NSWindow` 中回归分栏布局、工具栏和状态同步，包括捕获按钮在浏览器名称、启动/停止及禁用状态变化后的宽度、图标布局与动作，以及纯 AppKit 窗口下在 1100/1440/1800 pt 窗口中调整左右分隔线后，工作区仍贴住窗口左右边缘、窗口大小保持不变和可见栏最小宽度。它与完整 App 的外观、鼠标交互和真实数据验收分别报告，不能以隐藏窗口回归代替视觉验收。

`check-inspector-performance.py` 进一步使用真实请求表格和详情组件、75 条替身记录，在隐藏窗口反复选择、展开、缩放和收起详情，检查空闲 CPU 与相同快照下工具栏图像的稳定性。页面控制器保留既有视图层级与明确尺寸约束，工具栏快照相同则跳过控件赋值，避免重复布局更新；隐藏窗口测试仍不能替代实际 App 的性能验收。

详情内容复用 `ToolbarSectionControl`，直接使用 `NSSegmentedControl` 展示请求头、查询参数、请求体、响应头、响应体五项；macOS 26+ 用控件自身的 `borderShape = .capsule` 配置胶囊形状，macOS 27+ 设 `.tabs` 语义，继续使用 `.automatic` 分段样式；主工作区和设置保留其既有布局。内容 Tab 使用 `.fillProportionally` 按标签自然宽度分配可用空间，保证查询参数四字标签和 400 pt 窄栏完整展示，macOS 26+ 采用原生 `.extraLarge` 尺寸，旧系统使用 `.large`，不再以 `.fit` 紧凑居中；同一行右侧放置原生复制按钮。该行使用固有高度；分段与复制按钮均配置垂直 hugging/compression 优先级，复制桥接实现 `sizeThatFits`，防止其抢占内容区高度并将 Tab 推到侧栏中间。当前可见 Payload 通过 Preference 提供复制内容及其 Tab、版本，切换中或数据不可用时禁用复制，防止复制上一页内容。形状与绘制均由 AppKit 提供，不添加 `NSGlassEffectView` 包装。

显示模式“修改前 / 修改后 / 修改对比”位于详情更多菜单的“显示选项”子菜单，以原生菜单勾选当前项。Inspector 级状态默认修改对比；五个内容 Tab 共用该值，收起重开或选择不同记录时保留。各 `RequestPayloadView` 独立保留搜索、树展开、滚动和树形/原始数据格式。

`RequestPayloadControls` 底部只保留搜索和 JSON 原始数据切换，横向 12 pt、纵向 10 pt 留白与左栏一致。底部格式切换与 Tab 右侧复制使用原生 `NSButton`，macOS 26+ 采用控件自身的 `.glass` bezel 样式，分别为 `.capsule` 与 `.circle` 形状，不叠加玻璃容器；旧系统采用对应的原生圆角或圆形按钮。`NSSearchField` 使用 `.large` 系统搜索外观，不额外添加玻璃包装。请求体、响应体的 JSON 格式在“原始数据”与“树形视图”之间切换，不改变当前显示模式。`RequestInspectorView` 固定摘要，方法使用共享的原生只读 `RequestMethodLabel`，状态码使用原生只读 `NSTextField`，沿用系统语义色和必要字体；14 pt 的原生 `NSPathControl` 按“规则组 > 规则”展示捕获名称，点击后按捕获的工作流 ID 直接跳转请求修改，已删除目标禁用。查询参数作为请求头后面的 Tab，来自原始/最终 URL，支持显示模式、搜索与复制，不混入 Body；`RequestDataOutline` 通过 `NSOutlineView` 提供 Header 和 JSON 字段树。原始数据使用只读 `NSTextView`，保留文本缩进、换行和字段顺序，不重新格式化；非 JSON 直接显示文本或十六进制，不提供无效切换。Payload、Outline 和 Source 不再设置独立白背景，由系统 Inspector 背景贯穿；字段仍仅用系统色的低透明度背景表达变更。原生按钮在行悬停时以 0.15 秒淡入淡出并复制值或完整子树，遵循减少动态效果设置；提供右键与键盘替代。`RequestInspectionData` 在后台构造差异和节点，隐藏/不完整数据不产生推测性差异。系统侧栏建议宽度 520 pt，可在 400–760 pt 调整。外观与鼠标交互仍待 App 运行验收。

`CaptureBodyCollector` 随流量完整记录原始请求、发出请求、服务器响应和最终响应，`CaptureBodySnapshot` 共享不可变内容，不设置单快照尺寸或全局 Body 预算。URL 和 Header 完整保留，所有凭据与环境变量直接显示原值。记录包括完整、未完成、未采集和不可用状态，Mock 无上游原始响应。写入失败不会被后续结束标记成功掩盖。`RequestBodyDecoding` 只对完整快照在详情后台任务中使用系统 zlib 解码 gzip / deflate，不设置解压输出尺寸和编码层数上限；JSON 树不设置应用层字节数、层数和节点数上限。Body 预览不落盘，详见 [性能边界](Performance.md) 与 [请求详情设计](Design/request-inspector.md)。

详情顶部以原生 `NSTextField` 标签承载单行中间省略的 URL，使用系统默认文字颜色，保留原字号与系统全文悬停提示，点击不再打开弹窗。同一行最右侧提供原生圆形复制按钮，macOS 26+ 使用控件自身的 `.glass` 样式，点击调用 `RequestClipboard.copy(record.url)`；`urlWasTruncated` 时禁用完整复制并通过按钮提示说明原因。

更多菜单由工作区的 `NSMenuToolbarItem` 承载，设 `isBordered = true` 使用系统按钮外观，位于展开侧栏工具栏的收起按钮左侧，折叠时隐藏，不再占用 URL 摘要。菜单依次提供“复制完整 URL / 复制原始请求为 cURL / 复制修改后请求为 cURL”，不完整时禁用相应项并提供原因。`RequestCURL` 使用原始或发送快照导出，正文保持采集的实体字节，不复用解压或格式化后的显示文本；传输分帧与长度交给 curl 重建。URL、Header 或 Body 不完整时不生成误导性的完整请求，Header 原值直接用于导出。命令只在用户点击复制时构造，不自动执行请求。

`RequestDataNode.jsonStringValue` 保存可检查字符串的实际值，与显示摘要、JSON 引号及复制载荷分开；Header 按当前显示版本的完整性决定是否提供该值。行悬停时通过后台任务调用 `RequestInspectionData.stringJSONPreview`，复用既有 JSON 解析限制与节点生成；成功后用原生按钮打开 `NSPopover`，其原生 `NSViewController` 内容仍是 `RequestDataOutline`。解析不替换原节点，嵌套字符串按需逐层检查，不预先递归解码所有字符串。

统一启动由 `WorkspaceModel.toggleCapture` 编排。全局模式通过 `CaptureService.start(..., mode: .systemProxy)` 监听并接管系统代理，不启动浏览器；浏览器模式先发现并校验所选应用，再通过 `.browser` 仅启动监听，最后由 `BrowserLauncher` 使用 NSWorkspace 和代理参数启动应用。浏览器启动失败关闭本次监听并在主窗口提示；没有浏览器也不影响全局模式启动。偏好保存在 UserDefaults，默认维持全局接管；实际会话固定 `activeMode` 和浏览器快照，运行中修改偏好不改变当前流量范围。停止与退出依据实际会话执行。

`ChromiumBrowserCatalog` 合并系统注册的 HTTP/HTTPS 应用与系统、用户 Applications 目录，在后台检查网页声明及 Chromium 框架资源，兼容带版本的 Framework 目录，排除更新缓存、废纸篓与 App Translocation 副本，按 Bundle ID 去重并优先使用系统推荐安装，不依赖浏览器名称白名单。启动前重新校验应用，专用数据目录按 Bundle ID 与端口隔离，保留既有 Google Chrome 目录。`BrowserLauncher` 在宿主生命周期内持有按应用路径与专用数据目录区分的 `NSRunningApplication`，独立于捕获会话；停止捕获不清理浏览器记录。再次启动先校验应用并移除已退出进程，同浏览器、同端口的存活实例只激活原窗口，不重复发送 `--new-window`；没有存活记录时带原代理参数重新启动，继续使用原数据目录。切换后返回先前浏览器或端口也可复用对应的存活实例。记录仅在内存中保存，不跨 Requestman 重启恢复，不保证恢复用户已关闭的标签页。浏览器替身检查覆盖复用、隔离、退出、失败重试及目录保留，不启动真实浏览器。发现或启动成功不等同于已观察到代理流量，各 Chromium 衍生浏览器对启动参数的支持仍待逐一运行验收。

两种启动方式共用 `CaptureStartupPreflight`：先校验配置，启用上游时经 `CaptureService.checkUpstream` 调用 `UpstreamProxyProbe`，使用 Network.framework 尝试 TCP 连接，设置 3 秒总时限并支持取消。成功或超时后关闭探测连接，不访问外部测试网站，不验证代理协议、认证或目标可达性。检查失败由 AppKit sheet 提供“关闭上游并启动 / 继续使用上游 / 取消启动”；只有明确选择关闭才修改并保存上游配置。检查与选择都在监听、系统代理接管之前完成；期间禁用重复启动和连接配置编辑。探测遵循 [NWConnection 状态](https://developer.apple.com/documentation/network/nwconnection/state-swift.enum)，不读取系统 HTTP 代理来建立到上游的连接。

连接配置停止输入约 350 ms 后由 `WorkspaceModel` 串行应用，期间与启停、浏览器启动和退出互斥；防抖取消不取消已经开始的系统设置事务。上游配置经 `LocalProxyServer.updateConfiguration` 更新，新连接读取独立配置快照，现有请求与隧道保持原路由。端口变更通过 `CaptureService.restart` 自动先停止再启动，显式传递当前 `activeMode`，失败回滚也保留模式。停止恢复失败时保留原监听，新配置启动失败且没有必须保留的监听时尝试恢复旧配置。浏览器会话切换端口后，为当前会话浏览器复用新端口上的存活调试实例，无可复用记录时打开新窗口，不使用可能已改动的下次启动偏好；旧窗口不自动关闭。设置页显示错误并同步实际监听状态。

`CaptureEngine` 的全局会话先监听再调用 `SystemProxyController` 接管，先恢复系统设置再关闭监听；浏览器会话的正常启动、重配、回滚和停止不调用系统代理服务。全局恢复失败保留监听与恢复文件，并阻止正常退出；UI 同步仍在运行的监听端口。上次异常退出的系统代理恢复由 App 载入时独立执行，失败时记录待恢复状态，阻止新浏览器会话沿用残留全局代理；下次启动动作先重试旧会话恢复，退出也会重试。`SystemProxyController` 在独立 actor 中锁定网络偏好会话，按服务 ID 保存原配置后统一 commit/apply。接管当前网络位置中已启用且支持代理协议的服务，临时关闭 PAC、自动发现、SOCKS 和绕过列表；恢复仅覆盖仍与接管值一致的字段组，保留其他工具的新设置。恢复文件写入成功后才能设置代理，恢复 commit/apply 成功后才清空记录。没有常驻恢复 helper；新增网络服务或切换网络位置后需重新开始全局接管。API 的持久化与运行时应用是两个步骤，见 [Apple SCPreferences 文档](https://developer.apple.com/documentation/systemconfiguration/scpreferences-ft8)。

`RequestmanCore` 已提供 `FlowExecutionRuntime`：不可变计划/环境版本、按需 Body 读取、有界准入、可批量读取的元数据环形缓冲。它与 UI、数据库和代理框架无关，详细容量、取消与接入契约见 [性能与资源边界](Performance.md)。基础代理在 NIO 事件循环直接执行 metadata/static-body 动作，使用连接准入和写完成后的拉取背压；不把每个网络块转成 Swift Task，也没有把两套准入队列叠加。`FlowExecutionRuntime` 为后续需要完整 Body 的异步动作保留，尚未包裹 NIO 转发。

## 规则命中通知

捕获会话的规则命中通知通过独立的 `RuleHitNotificationBuffer` 传递。`ProxyConnection` 在事务协调器调用 `RuleMatchingEngine.match` 成功后、步骤执行与请求正文等待之前写入工作流 ID 和名称；它表示匹配成功，不表示后续步骤或网络请求成功。通知不依赖完成记录，因此慢请求、脚本等待、日志暂停和日志清空不会抑制命中提示。`CaptureEngine` 为全局接管和浏览器两种会话启用该缓冲，启动失败、停止或监听重启时重置，并通过会话 ID 阻止旧批次继续发送。

聚合使用 `ContinuousClock` 单调时间，每轮固定为首次命中起的 `[0, 3s)`，新命中不续期。轮内以工作流 ID 去重，名称采用首次命中的快照；每轮独立 UUID 作为系统通知标识。缓冲合并尚未读取的同轮更新，最多保留 64 轮待发送快照；宿主独立于历史记录每 200 ms 串行消费，避免通知服务等待影响请求转发或日志读取。首条在下一次消费时提交，不等满 3 秒。达到边界后的命中新建标识；到期本身不触发动作，已送达通知不主动删除。

`SystemRuleHitNotifications` 在 App 启动完成前注册 `UNUserNotificationCenterDelegate`，在用户启动任意捕获模式时检查并按需申请 `.alert` 权限。使用标题“规则命中”、逐行规则名称正文和空 trigger 提交无声本地通知；轮内复用标识更新，前台返回 `.banner` / `.list`。发送前重新检查授权与会话有效性，拒绝或发送失败不阻止捕获，错误写入系统日志。没有 APNs、网页注入或辅助功能权限依赖。`RuleHitNotificationTests` 覆盖固定边界、重复 ID、同名不同规则、积压合并及会话隔离；代理测试覆盖匹配时机与未命中；`check-rule-hit-notifications.py` 使用通知中心替身检查权限、正文和标识，不请求真实权限、不发送系统通知。真实横幅、权限弹窗和通知中心替换效果仍须完整 App 人工验收。

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

当前支持 HTTP/1.1 与 HTTPS 上的 HTTP/2 内容处理，以及未配置证书时的 CONNECT 字节透传。HTTP/2 每个 stream 独立执行规则并采集日志，同客户端会话内复用同目标上游连接；两端保持同协议，不降级、不转换、不自动重发。范围、生命周期与验证见 [HTTP/2 捕获与修改](Design/http2.md)。SSE 与 WebSocket 基础支持见 [持续捕获](Design/streaming-capture.md)；HTTP/3、自定义 TCP/UDP 后续分别定义能力边界。上游可直接 TLS 或经 HTTP 代理 CONNECT 后 TLS。证书绑定应用不能仅靠安装本地 CA 获得支持。

系统代理接入只影响遵循 macOS 代理设置的应用，并非全流量透明接管。上游连接使用 NIO socket，不读取指向 Requestman 的系统 HTTP 代理，避免递归；显式配置指向自身的上游仍拒绝，连接完成后再检查解析后的地址。

按应用透明接管模式中，应用列表的 Bundle ID 是用户选择键，不能等同于网络流的签名身份。实际接管必须解析签名信息、审计令牌及辅助进程归属，避免误捕获。空选择必须拒绝启动，不能退化为全局捕获。未来显式代理入口需要独立的配置与校验契约，不通过放宽现有 CaptureConfiguration 的空选择校验实现。

请求流程在主请求发往上游前执行，响应流程在对应内容返回客户端前执行。Mock 跳过主上游请求并进入响应流程；辅助 HTTP 请求独立标记，默认跳过普通流程匹配。响应的“添加延迟”以 ms 保存，`ModificationExecutionEngine.executeAsync` 按步骤异步等待，结束后才继续，保留阶段入口的模板快照。含延迟的响应复用完整 Body 后台流程，纯延迟不进行文本解码、不占用脚本名额；取消随流程传递，HTTP 事务和流程预览不设总时限；单次脚本超时独立保留。客户端仍可主动断开或按自身策略超时。完整 Body 编辑、头部处理与流式透传的边界见产品设计文档。

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

匹配配置统一为 `WorkflowMatchGroup`，支持全部 / 任一嵌套组、方法集合、URL / Host / Path、协议、端口、Query、多 Header、Cookie 和 Content-Type。工作区保存版本为 3，不迁移旧匹配配置；真实代理和测试匹配共用组逻辑，保持修改前匹配与首个启用流程优先。步骤详情接入同一个窗口级 Inspector，Header 使用插件候选列表的原生可编辑组合框。同步 JavaScript 通过可终止的独立进程执行，具有脚本的阶段在后台读取完整 Body、解码文本后执行；未带脚本的阶段保留 NIO 流式路径。取消沿脚本流程传递，单次脚本限时独立于无总时限的事务；输入/输出没有新增载荷尺寸上限。完整 API、并发和时限、验收范围见[请求修改配置](Design/request-modification.md)。

## AppKit 界面迁移（2026-09-26）

`FlowEditorViewController` 的匹配条件首行提供“测试匹配”，通过 `WorkflowMatchTestViewController` 原生 Sheet 输入请求方法、URL 和示例 Header。`WorkflowMatchTest` 在独立后台任务中复用 Core 匹配器，输出条件级诊断及首次匹配范围；不触发代理、步骤或脚本执行。规则摘要是打开时的快照，示例不持久化，输入变更及关闭对话框使旧任务结果失效。匹配测试只检查条件，规则启用状态及规则顺序仍由实际捕获处理。

`RequestmanEntry` 在处理脚本 worker 参数后创建 `NSApplication`。`WorkspaceAppDelegate` 安装系统菜单、持有主窗口和设置窗口，负责启动加载、前台证书状态刷新、后台保存及退出前恢复代理。所有界面与测试替身移除 SwiftUI 和 Hosting 桥接，核心 Observation 模型、代理、证书及脚本契约保留。`check-native-sources.py` 同时检查工程源引用及 AppKit-only 约束，阻止重新引入声明式桥接。工作区、请求详情、筛选、Header、规则编辑和设置使用隐藏 AppKit 窗口回归；完整 App 的系统外观、真实鼠标体验与浏览器网络验收仍单独报告。

设置分组使用独立的原生文本标题，与系统 `NSBox` 保留 8 pt 间距；内容视图显式约束到分组四边并保留 12 pt 内边距，让证书按钮、错误提示与上游行隐藏或展开后仍由内容决定高度，超出窗口时滚动。`check-settings-ui.py` 检查标题间距、内容留白、控件高度以及证书未配置、失败、已配置之间的切换，使用只读证书替身，不操作真实钥匙串。

动态环境表单在重建后更新键盘焦点顺序，同一变量的名称与值支持 Tab / Shift-Tab 切换。共用 `ActionTextField` 保留输入时更新，结束编辑时同步最终值，回车提交并取消焦点；输入法正在组字时仍交给原生编辑器处理。窗口内点击当前输入区域之外时，`NativeTextEditing` 通过应用内鼠标事件监听先结束编辑，再继续传递原点击事件；多行正文与脚本编辑器保留回车换行。设置与规则隐藏窗口回归直接操作 AppKit field editor 和鼠标事件验证这些行为。


环境编辑中的“删除环境”按钮直接放在表单底部，不再使用独立分组或底部说明。环境名称输入时检查其他环境的名称（忽略首尾空白，区分大小写）；重名时显示字段错误、保留待修改输入，并阻止该名称写入工作区，修正后继续自动保存。

## 规则组与配置归档（2026-09-26）

`WorkflowProject` 保存规则组名称、SF Symbol 名称 `symbol` 与规则列表，不再具有启用状态。`RuleMatchingEngine.match` 只检查每条规则的启用状态；组菜单通过 `WorkflowProject.setWorkflowsEnabled` 批量写入所有请求修改的启用状态。旧配置中的组禁用在解码时一次性转换为每条规则禁用，新保存数据不再包含组开关。规则组树使用原生 `NSOutlineView` 和 `NSMenu`，规则组/请求统一 30 pt；单击选择、双击整行展开收起，名称通过菜单编辑，请求行不展示匹配摘要。禁用规则的行内容使用 45% 透明度并显示停用标记，规则组保持正常外观，菜单保持可操作。右键菜单交给 `NSOutlineView.menu(for:)` 的系统实现跟踪目标行，为未选中项显示原生边框并在菜单关闭后清理，不改变当前请求选择。

`WorkspaceArchive` 定义 `requestman.archive` v1，区分 workspace/rules/project/workflow 四种范围；单条保留完整 `RequestWorkflow`，两阶段步骤、脚本选项及 Header 匹配均按原数据编码。全量保存 `WorkspaceDocument` 与应用 UserDefaults 持久域的二进制 plist，JSON 以 Base64 承载该 plist。仅归档配置，不读取证书、钥匙串、浏览器 profile 或系统代理恢复文件。核心合并逻辑为所有导入规则组及后代重新生成 ID，再追加到当前规则组；仅设置页导入全量范围时替换环境和代理配置。文件菜单的独立分组提供“导入规则…”与“导出全部规则…”，`rules` 范围保存所有规则组（包括空组）及完整规则，不保存应用偏好；文件菜单导入完整备份时先转换为规则范围，沿原持久化通道追加，保留当前环境、代理与偏好。单条 `workflow` 导入创建使用本地导入时间命名的“导入 yyyy/MM/dd HH:mm:ss”规则组，整组和全部规则保留组名与顺序。

`WorkspaceTransfer` 使用原生文件面板和后台文件 I/O。宿主完成校验后暂时禁用编辑、取消待保存任务，先通过串行 `WorkspaceDocumentStore` 保存合并快照，再发布模型和恢复偏好；文件写入失败保留原模型。偏好恢复通知使已有 `RequestRecordsTable` 立即重新读取列宽。捕获服务收到新工作区快照，代理配置变化仍走现有串行重配，不复制捕获运行状态或触发证书操作。

`WorkspaceArchiveTests` 覆盖完整内容往返、三种导出范围、重复追加和 ID 隔离、环境覆盖、未知版本/坏文件拒绝、旧规则组默认值与批量禁用规则后的匹配与旧组开关迁移。规则 UI 检查覆盖行高、隐藏副标题、空白区/箭头整行点击与菜单动作；请求列表检查覆盖已存在表格的列宽恢复。隐藏窗口回归与完整 App 的文件面板和视觉验收分别报告。

带边框的单行表单输入框由 `ActionTextField` 统一使用原生 `.squareBezel`、浅色控件外观和白底黑字；`HeaderNameField` 可编辑组合框不绘制背景，不固定外观和文字颜色，跟随系统原生样式。不添加背景容器或自绘控件。JSON 路径框保留系统原生凹槽边框，跟随所在窗口的外观并使用系统文字与背景颜色，不强制白底。普通单行表单输入框与 Header 组合框统一使用 32 pt 固有高度；文字与 field editor 垂直居中，标题编辑保留独立布局。请求名称平时显示无边框标题，仅在编辑时显示原生圆角输入框；按系统文字内边距补偿布局，使两种状态的文字都与下方条件标题左对齐。文字布局宽度优先为 450 pt、窄窗口可收缩，编辑框高度至少 40 pt，跟随窗口外观；编辑前后保留文字位置；单行文字与原生 field editor 使用同一块按字体实际行高垂直居中的区域。规则隐藏窗口回归对匹配值、查询参数、URL 查找、状态码、延迟及脚本备注进行聚焦前后像素与输入检查，Header 组合框和 JSON 路径框保留编辑行为检查，不断言白色填充；Inspector 字段放入真实分栏层级检查，缓存像素检查不能替代屏幕合成效果验收。

## 工作区键盘命令

请求修改页的“预览流程”固定在主栏底部左侧，独立于正文滚动区；侧栏添加与搜索、主栏预览、步骤详情添加与删除使用 36 pt 高的底部操作行和 8 pt 底部留白，按钮垂直居中对齐。

通用设置在全部分组下方提供“清除工作区…”原生按钮，使用 `NSAlert` Sheet 二次确认，默认按钮为“取消”。`canClearWorkspace` 允许已加载或读取失败后的工作区执行清除，首次加载及操作进行中禁用；读取失败后的清除若再失败，继续禁用编辑且不自动保存未加载的空快照。`WorkspaceModel.clearWorkspace` 与捕获启停、导入和重配互斥，暂时禁用工作区编辑；等待已开始的自动保存结束后，先停止捕获并完成系统代理恢复，再保存空 `WorkspaceDocument`，成功后才发布模型并清空日志、选择、筛选及暂停状态。失败保留配置和日志，已停止的捕获不自动重启。清除不删除证书、浏览器数据或 UserDefaults；工作区代次防止之前的异步 Mock 创建结果重新插入规则。`check-settings-ui.py` 覆盖按钮位置、取消/确认以及使用真实宿主模型和临时文件的失败、持久化与过时自动保存检查，不操作真实代理和证书。

`WorkspaceCommand` 定义固定映射，由 `WorkspaceAppDelegate` 安装到原生菜单，由 App delegate 转交 `WorkspaceSplitController`（即使没有文本或列表焦点也能使用）。菜单校验与执行共用 `canPerform`，检查当前 key window、sheet、加载状态、捕获过渡状态、页面、选中记录完整性和列表焦点；不安装全局键盘监听。启停捕获复用 `WorkspaceModel.toggleCapture`，暂停记录和清空复用既有 history 接口。侧栏上下文菜单和快捷键共用规则组 / 规则动作，步骤动作按实际聚焦的阶段列表定位，文本编辑器保留原生编辑按键。

规则组行支持原生键盘选择，刷新时保留规则组选择与现有流程上下文；新请求优先放入侧栏所选规则组。环境弹层的搜索框和列表分别处理方向键、回车和 Escape，候选移动不立即切换环境，关闭后恢复工作区焦点。`check-workspace-sidebar.py` 验证原生菜单派发和窗口 / 状态限制，`check-rules-ui.py` 验证焦点与删除边界；这些隐藏组件窗口检查不等同于完整 App 的真实键盘验收。

侧栏删除规则组与单条规则时，菜单和快捷键统一弹出原生 `NSAlert` Sheet 二次确认，默认按钮为“取消”。弹窗显示目标名称，删除规则组还显示组内规则数量；仅明确点击删除后按原目标 ID 执行，确认前重新检查工作区可编辑且目标仍存在。取消不修改数据，也不改变当前规则选择。

## 多 Header 与动态模板编辑（2026-09-26）

`ModificationStep.headers` 为统一“修改 Header”步骤保存可增删条目及各自的 `add` / `modify` / `remove` / `set` 操作，同一步可按顺序添加、修改、删除及添加或覆盖。添加始终追加，修改只更新已有同名项的值并保留其名称、数量和顺序；没有匹配时跳过。`set` 在详情中以“添加或覆盖”提供选择，先移除所有同名项再添加新值，无匹配时直接添加；旧配置保留原有语义；Header 条目下方不展示操作说明或旧配置兼容说明。旧条目缺少操作时按 `setHeader` / `removeHeader` 类型读取，缺省数组时读取旧 `name/value`；显式空数组表示不操作。`HeaderProcessor` 在整组解析与校验通过后才应用，保证后续条目失败不会留下半组修改。删除只校验名称；删除和未匹配的修改忽略保存的值。编辑器逐条提供原生修改方法下拉框，删除时隐藏值、切回保留值；添加菜单仅保留统一入口。区块显式约束内容边距，滚动文档固定顶部与水平起点。`$env.` 是新的环境引用前缀，旧 `env.` 保持兼容，单次替换语义不变。

步骤 Inspector 在 macOS 26+ 使用安装到右侧 `NSSplitViewItem` 的底部 `NSSplitViewItemAccessoryViewController` 承载 footer（26.1+ 的边缘样式为 `.soft`），正文滚动视图铺满面板，系统内容 inset 保证首尾字段可达。footer 无分割线；附件栏随选中步骤和页面可见性隐藏，旧系统使用无分割线的固定布局。配置表单仅在内容超出可见高度时滚动，滚动条自动隐藏，外层表单关闭弹性回弹；底部移除排序按钮，红色删除按钮使用 transient `NSPopover` 确认，并检查原步骤、工作流和阶段仍匹配。Header、查询参数与 URL 模板文本继续使用原生 `NSTextView` 的纯文本编辑、撤销和复制；`TemplateLayoutManager` 只绘制完整表达式的浅蓝圆角背景和文字颜色，值编辑器使用 `NSScrollView.borderType = .bezelBorder`和系统文本背景色，边缘由 AppKit 绘制，不设置图层圆角或自绘焦点框；当前系统原生多行边框为直角，不保证与单行框的圆角相同。脚本编辑器不启用模板标记。内置变量与格式见[内置变量](Design/request-modification.md#内置变量)。`WorkflowTemplateContext` 在代理匹配原始请求后生成时间、随机值和原始请求快照，流式执行与脚本后台执行显式传递同一 Sendable 值；本地预览同样共享上下文。响应状态码在响应流程入口固定，Mock 使用本地生成状态码。模板标记按 Core Text 的实际字形轮廓垂直居中，左右扩展 4 pt，背景围绕文字中心对称限制在实际行高内；排版基线居中，24 pt 行高为相邻 20 pt 标记保留至少 4 pt 间隔，短值编辑器可完整显示两行。

步骤图标和名称位于窗口工具栏原“步骤详情”位置，下方显示不超过 25 字的类型说明，替代阶段与序号；主副标题间距为 4 pt，原生启用开关使用 `.small` 尺寸，位于收起按钮左侧；开关左侧以 11 pt 次要文字显示“已启用 / 已停用”，间隔 6 pt，随当前步骤状态同步。顶部与左侧栏一样沿用原生工具栏及全高内容布局，由 AppKit 管理默认滚动边缘，不安装顶部附件或显式覆盖边缘样式；正文不重复标题与说明；每个 Header 使用独立 `NSBox`，添加按钮固定在 footer 左侧；它与所有步骤 footer 右侧的删除按钮使用原生 `.glass` 样式与 `.capsule` 形状（macOS 26+），使用系统 `large` 控件尺寸。Header、查询参数操作与 URL 字符串替换配置区块右上角的移除按钮统一使用 24 pt 原生圆形减号按钮，保留删除提示与辅助功能名称。`StepInspectorViewController` 在底部左侧添加按钮右边提供独立的原生圆形 info 按钮，两个按钮间保留 12 pt 空隙；没有添加操作的步骤仍在左下角显示 info。按钮使用自身的系统样式，不使用共享玻璃容器。`TemplateValuesViewController` 在按钮上方的 Popover 内展示内置变量和当前环境变量名称；重建表单、切换步骤、收起侧栏或关闭窗口时关闭弹层。原生复制按钮按行悬停淡入淡出，键盘焦点与减少动态效果均有替代行为。`TemplateLayoutManager` 用仅影响排版的字距属性为变量与普通文本保留实际空隙，不修改底层字符串。

环境管理首组使用“名称”标题和单个输入框，环境切换保留在主窗口。变量行提供字符串、数值、布尔、数组、对象类型；`NamedValue.type` 持久化类型，旧配置缺少类型时默认为字符串。非字符串值按 JSON 格式校验，无效编辑保留为当前表单草稿并显示错误，合法后才保存。模板按文本插入变量值；代理、流程预览和脚本试运行传递同一环境快照的类型，脚本 `env` 将非字符串解析为对应 JavaScript 值并递归冻结。

## HTTPS 域名解密范围

`WorkspaceDocument.httpsDecryption` 保存 `HTTPSDecryptionConfiguration`：`decryptAllRequests` 默认开启，缺少配置的旧工作区保持全部解密；关闭时由 `domains` 决定，空列表全部透传。精确域名和 `*.` 子域名通配符按 DNS 标签边界匹配，忽略大小写与单个末尾点；通配符不含根域。设置编辑器以英文分号 `;` 分隔域名，逐项去除首尾空白后校验，空项忽略；回显同样使用英文分号。错误草稿不写入工作区，未校验的无效模式在匹配时也不扩大解密范围。

代理在 CONNECT 协议识别后读取最新工作区范围，只有 TLS 且范围命中时才调用证书提供方；未命中直接沿既有 `connectOpaqueTunnel` 路径转发，不读取 CA、不签发叶证书，也不进入 HTTP 规则与内容采集。证书不可用仍沿原有透传或错误路径处理，普通 HTTP 与 CONNECT 内明文 HTTP 的既有行为不变。范围通过原工作区保存/更新通道应用，不属于需重配监听的 `ExplicitProxyConfiguration`，现有连接保持原模式。全量归档包含该配置，规则组/请求归档合并不覆盖当前配置。

验证覆盖旧工作区解码、保存与归档、域名边界、空列表和全部开关；本地 TCP/TLS 测试通过客户端仅信任预期签发方确认透传没有 MITM，并检查证书提供方调用次数、规则是否执行、日志内容以及 HTTP 上游串联。设置采用原生 `NSSwitch` 与 `NSTextView`；域名输入区使用原生 `.bezelBorder`，文本未超出可见高度时将滚轮事件传给外层设置页，超出时保留内部滚动。开启全部解密或工作区不可编辑时，域名输入区禁用编辑与选择、取消焦点，使用系统禁用文字色与 `.controlBackgroundColor`，不自行混合背景颜色。隐藏窗口检查覆盖开关、有效输入、错误草稿、导入刷新及短文本/长文本/缩短后的滚轮分发；不等同于完整 App 的浏览器运行验收。

## 本地 Body 文件映射

`ModificationStep.bodySource` 区分文本和文件，旧配置缺省时保持文本；`bodyFilePath` 与原有 `value/bodyEncoding` 独立保存。两类 Body 步骤使用 `NSOpenPanel` 选择文件，原生分段控件切换来源。引擎每次执行读取普通文件原始字节，失败不修改草稿。代理文件步骤复用后台流程执行器，文件替换无需等原 Body 完整：请求沿用待发送队列，响应只暂停上游继续读取，当前批次仍采集原始数据。文件读取完毕后恢复流式消费；含脚本或延迟时继续采用原有完整 Body 路径。归档只保存本机路径，不包含映射文件内容。

## 独立代码编辑器

`Packages/RequestmanEditor` 由 Body 与 JavaScript 表单共用。文本编辑、布局和撤销使用 CodeEditTextView 0.12.1；语法颜色由 HighlighterSwift 3.1.0 在独立 actor 中计算，80 ms 合并输入，回到主线程前检查文本和版本，忽略过时结果与输入法组字期。仅更新颜色属性，不重写正文、选择或撤销记录；明暗主题使用 atom-one-light / atom-one-dark。行号复用 CodeEditSourceEditor 0.15.2 的 MIT GutterView，移除折叠和控制器依赖，直接使用同一个 TextLayoutManager 的行几何；不引入其 SwiftUI 界面。正文与行号共用原生滚动视图的 `.bezelBorder` 和系统文本背景色，不设置额外圆角裁切。短文本把滚轮传给外层表单，长文本保留内部滚动。

Body 解析模板开启时，完整表达式用浅色背景标识；字面值和 Base64 不标识模板。格式化继续使用 BodyJSONPresentation 保留数值原始拼写和模板，通过编辑器的替换接口形成可撤销操作。Header 等普通模板字段仍用 RulesTextArea；移除旧 BodyLineRuler 与 JavaScriptSyntax。依赖许可证随编辑器资源包提供，来源与改动见 [编辑器说明](../Packages/RequestmanEditor/README.md)。

## SSE 与 WebSocket 持续记录

`CaptureRecordBuffer` 按稳定 ID 合并活动快照，`ExecutionHistoryModel` 更新原行；清空通过代次隔离旧连接。SSE/WS 载荷由 `CaptureStreamStore` 在后台串行写入会话临时文件，界面按页读取。SSE 根据上游原始响应 Content-Type 自动识别，`isSSE` 配置标记及手动 Header 修改不触发协议转换；有限 Body 替换取消上游，延迟不等待 EOF。WebSocket 基于 NIOWebSocket，CONNECT 区分明文与 TLS，握手完成后切换双向帧管线。具体协议边界、规则兼容和存储生命周期见 [持续捕获](Design/streaming-capture.md)。


## 请求重放

详情更多菜单与日志右键菜单共用 `RequestActionsMenu`，依次提供重放分组、复制子菜单；详情复制子菜单额外提供随当前 Tab 和显示模式变化的内容复制项，打开菜单时固定内容快照。URL 与字段右侧保留快捷复制按钮。详情末尾单独提供显示选项，列表末尾单独保留 Mock。菜单冻结打开时的记录，不追随随后变化的选中行。

`RequestReplayDraft` 从完整原始请求提取方法、URL、重复 Header 和原始 Body 字节；原始记录不被覆盖。“重新发送请求…”使用原生 AppKit sheet：方法使用仅供选择的 NSPopUpButton，保留原请求扩展方法选项，Header 使用可增删的 NSTableView，保留重复字段、顺序和未编辑值的空白；正文复用 RequestmanEditor.CodeEditorView 的行号与 JSON 语法着色，可编辑方法、URL、Header 和 UTF-8 正文；压缩或二进制正文以 Base64 编辑，保留 Content-Encoding，不执行模板解析。输入实时校验，Host、Content-Length 与逐跳字段由传输重建。

`WorkspaceModel → CaptureService.replay → CaptureEngine → LocalProxyServer` 仅在捕获运行期间发送，通过 NIO 向当前回环监听提交绝对 HTTP/HTTPS URL，复用代理规则、上游出口、TLS 校验和日志记录。HTTPS 由代理直接连接真实上游 TLS，无需建立客户端 MITM。重放不修改系统代理或证书设置、不跟随重定向、不读取浏览器 Cookie 存储。接收端流式丢弃响应字节，内容由代理记录，SSE 可持续观察，也可单独取消或随停止捕获关闭。每次发送分配独立重放 ID，并保留来源记录 ID；身份通过回环连接的端口关联，不添加 HTTP 元数据 Header。代理终态驱动完成、失败、取消反馈，提交成功不等同于响应完成。取消只关闭指定重放的客户端与下游连接，由既有事务清理关闭上游并取消规则执行。

手动重放的记录绕过日志暂停，普通捕获仍暂停；清空记录继续通过代次隔离阻止旧连接重新出现在日志。发送时定位新记录，当前筛选临时放行该记录，下一次修改筛选即结束放行，不改写筛选条件。日志顶部保留最近重放的状态、查看结果与取消按钮；每条活动重放的右键和详情菜单可独立取消。列表与详情显示重放状态，来源按钮可定位原请求；原记录已清空或淘汰时禁用来源入口。

WebSocket、加密隧道、未完整采集的请求及 CONNECT/TRACE 不提供 HTTP 重放；停止捕获或状态切换期间仅禁用直接重放；“重新发送请求…”仍可打开编辑窗口，实际发送时重新检查捕获状态，未启动时在窗口内提示并保留编辑内容。发送失败走工作区错误提示，代理执行和上游错误记录到新日志。

## 请求日志文件（2026-09-27）

`RequestLogArchive` 提供版本化 UTF-8 JSON 日志，`CaptureRecord` 的 Codable 保存消息与执行元数据，Body 明确区分文本和 Base64；流存储由串行队列冻结边界、独立读取句柄导出，并恢复为供详情分页读取的临时存储。正文完整性、活动连接状态和重放来源均保留。文件写入在后台逐条编码，完成后通过同目录原子替换发布；导入完整校验后才发布。

`RequestLogTransfer` 提供原生保存/打开面板，菜单保存只取 `ExecutionHistoryModel.recordsForSaving`，单条右键冻结所指记录。`ExecutionHistoryModel` 分离实时历史与打开文件，保留并恢复实时选择和筛选；文件记录不会被实时快照合并或淘汰。切换文件代次使详情重建载荷，避免相同请求 ID 的旧缓存。重放返回实时历史，文件中的活动重放不能取消真实连接。文件不携带规则配置、不自动触发网络动作。格式与交互见[保存日志](Design/saved-request-logs.md)。


## JSON 局部修改

请求和响应流程共用 `modifyJSON` / `JSONBodyProcessor`，有条目时声明完整 Body 和后台执行需求。`ModificationStep.jsonEdits` 保存有序路径操作；对象、数组导航和原始数字文本由独立解析器处理，每步仍由 `ModificationExecutionEngine` 原子提交。代理复用现有 gzip / deflate 解码，SSE 在无限 Body 上拒绝此步骤，有限替换后可执行。表单复用步骤 Inspector 的逐条原生分组、添加和删除行为。具体路径、类型、失败及归档契约见[修改 JSON](Design/request-modification.md#修改-json)。


## 文本域内边距

普通 AppKit 文本域统一使用左右 6 pt、上下 4 pt 的 `textContainerInset`，并将 `lineFragmentPadding` 设为 0，避免水平留白叠加。规则表单、试运行输入与结果、脚本帮助、HTTPS 域名、Body 源码和事件流原文使用同一规格；JSON 值直接沿用 `RulesTextArea` 默认值。Body / JavaScript / 重放正文的 `CodeEditorView` 将行号栏之后与右侧的正文留白设为 6 pt，行号区域与行高保持既有布局。


## 共享表单输入

普通表单输入集中在 [NativeInputs.swift](../Requestman/Features/Workspace/NativeInputs.swift)：`ActionTextField` 封装单行值变更、编辑结束和输入法安全的 Return；`.table` 用于原生表格内编辑；`ActionComboBox` 统一自由输入、候选选择和保留草稿的候选刷新；`ActionTextArea` 统一纯文本配置、禁用状态、内边距与内外层滚轮分发。`NativeInputMetrics` 集中维护普通表单的 32 pt 单行高度及多行字体、内边距。沿用现有单行外观与原生 ComboBox、文本域表现。

规则、匹配测试、环境、连接设置、重命名和重放表单复用这些组件；`HeaderNameField` 只提供 Header 候选与标签，`RulesTextArea` 只保留模板着色和光标行为。业务校验、字段标题、固定高度和提交动作仍由调用处负责。使用 `onChange` / `onSubmit` 等回调，不覆盖组件内部 delegate；程序设置文本不会触发业务回调。搜索继续使用系统 `NSSearchField`；Body、JavaScript 与重放正文继续复用 `RequestmanEditor.CodeEditorView`，只读载荷和事件流查看器保留专用实现。

## 局域网手机接入与设备来源

`ExplicitProxyConfiguration.allowLAN` 默认关闭，旧配置缺省为 false。主窗口仅在局域网监听实际生效、监听端口存在且不处于启停或重配期间显示 `iphone.gen3` 连接引导图标：右侧栏收起时在开关左侧，展开后位于 Inspector tracking separator 左侧，保留在主内容区；设置页只保留局域网开关。`LocalProxyServer` 根据该值绑定 `127.0.0.1` 或 `0.0.0.0`，同一端口接入本机、手机和重放；范围变化走 `CaptureEngine.restart` 的停止、重启、失败回滚流程。`activeConfiguration` 提供实际生效的配置，连接引导不根据尚未生效的草稿宣称可连接。上游 HTTP 转发与 CONNECT 继续复用既有传输；配置及解析后的地址检查覆盖本机局域网 IP，避免自循环。重放关联增加回环地址校验，远端同端口不再被识别为内部重放。

`MobileSetupHandler` 仅在局域网开启时处理发往本机监听地址的 `/requestman` 路径，提供引导页、公开 DER 和 iOS CA 描述文件；处理器在 CONNECT / WebSocket 升级前退出，避免接收解码器移除时释放的原始字节。下载不经过规则、日志或上游。`LocalCertificateService.publicCertificateDER` 只读取、解码并校验证书有效期，不访问私钥或修改信任。

`CaptureRecord.deviceSource` 保存规范化的客户端 IP（回环归为 `local`），贯穿 HTTP、HTTPS、隧道、SSE、WebSocket 与日志归档；旧记录缺省 nil。`WorkspaceDocument.deviceAliases` 保存别名；表格与详情从同一映射读取，修改后由 Observation 刷新已有记录，不改写历史请求和环境快照。设备来源可编排到任意列和行，仅在 `document.proxy.allowLAN` 开启时参与列表显示和搜索，并随设置即时刷新；只含设备来源的列在局域网关闭时隐藏，混合列中的其他内容仍显示。列宽分配和拖动仅计算可见列，隐藏时保留列宽偏好，旧环境列宽继续迁移到设备列。连接与使用边界见[局域网手机抓取](Design/mobile-capture.md)。

## 请求日志显示选项

筛选按钮左侧的“显示选项”打开原生 AppKit sheet，初始尺寸为 1320 × 780 pt。上方整体预览展示所有配置列；下方左侧增删列并调整顺序，中间编辑列标题、增删行和编排行内内容，右侧设置所选内容的字段、来源阶段、字段名、水平／垂直对齐、空值行为和外观。列列表固定 188 pt，内容设置固定 310 pt，中间列布局通过水平 `NSStackView.distribution = .fill` 占满剩余空间。对齐选择使用带 SF Symbol 的原生分段控件，以 `.fillEqually` 等分填满标签右侧，保留悬停提示与辅助功能名称；macOS 27+ 指定 `.tabs` 角色采用系统玻璃选择样式。macOS 26+ 的 `NSButton` 使用控件自身的 `.glass` bezel 样式，文字按钮为 `.capsule`、图标按钮为 `.circle`；`NSPopUpButton` 和 `NSSegmentedControl` 使用 `borderShape = .capsule`，旧系统保留默认样式。列列表与内容布局表格的白色背景、边框及圆角由原生 `NSBox` 的公开属性提供，白底容器局部使用 `.aqua` 外观解析原生文字与图标颜色，保证深色系统外观下的可读性；选中列的业务背景由 `RequestLogColumnListCell` 内的原生 `NSBox.custom` 提供，`cornerRadius = 8`，填充色为白色混合 25% 系统蓝；`NSTableView` 继续管理选择与拖放，`selectionHighlightStyle = .none`，控制器通过 cell 的 `setSelected` 直接同步选中状态，焦点转到其他配置控件时仍保留浅蓝圆角背景。字段按钮及所在 cell 使用 `focusRingType = .none`；字段按钮自身通过 `NSWindow.trackEvents` 区分点击与拖动，达到 4 pt 阈值后启动原生 `NSDraggingSession`，整行拖动仅从左侧柄或行标签发起；字段选中状态独立保存在业务布尔值 `isContentSelected`，原生按钮采用 `.momentaryPushIn`，不以 `.on` 表示业务选中状态；蓝色 `.systemBlue` bezel、macOS 26+ 的 `.primary` tint prominence、白色 attributed title 与辅助功能 selected 状态均由业务选中值派生，不再显示字段拖动图标。其他控件按固有尺寸排版，不叠加 `NSGlassEffectView` 等材质包装。列数由左侧列列表决定，空值配置属于每项内容；配置表单只保留顶部整体预览。

字段拖放先由 `contentDraggingImage()` 在独立透明位图中同步绘制普通原生按钮图像：`NSBitmapImageRep` 像素尺寸按源窗口 `backingScaleFactor` 计算，先将 representation 的逻辑 `size` 设为源按钮尺寸，再创建 `NSGraphicsContext(bitmapImageRep:)`，由 AppKit 处理逻辑坐标到像素的比例。绘制前按 `renderer.isFlipped` 将 Core Graphics 坐标平移到逻辑高度并执行 `scale(1, -1)`，再用 `NSGraphicsContext(cgContext:flipped:)` 同步标记绘制方向；保留既有 DPI 比例，不额外翻转 `NSImage` 或位图。局部 `NSButton` 使用 `.momentaryPushIn`、`.push` 样式、macOS 26+ 的 `.capsule` 形状，沿用源按钮字体、control size 和 `effectiveAppearance`，`state = .off`、文字为 `.labelColor`；其原生 `NSButtonCell.draw(withFrame:in:)` 在已清空的透明位图中完成绘制，保存并恢复 graphics context，已绘制的 representation 装入 `NSImage` 后再交给 dragging item。局部 renderer 不挂载窗口，不依赖源 View 的 `cacheDisplay` 或延迟绘图回调，也不修改或重绘源按钮；业务选中值、辅助功能 selected 状态和布局草稿保持不变。所有字段的拖拽图像使用同一种普通原生外观，源按钮保留由业务值决定的蓝色选中外观。随后保留原始 `mouseDown` 事件，由稳定的 `window.contentView` 启动原生 `NSDraggingSession`；拖拽 frame 使用 `host.convert(source.bounds, from: source)` 转换，避免滚动 document 的 `visibleRect` 裁切拖拽图像。鼠标按下时记录源按钮内的 `grabOffsetX`。拖动期间不修改布局草稿，源字段隐藏与同尺寸占位在一次排版中设置，避免中途 document 缩短导致 clip view 的滚动位置回退；目标位置使用同宽的半透明原生 `NSButton` 占位并推动邻近字段，位置变化以约 0.12 秒动画执行，减少动态效果开启时直接更新位置。同一目标位置重复悬停不重启动画；首项与原位放下同样有效，成功接收后才提交草稿，原位保持原顺序。指针靠近内容区左右边缘时通过原生 clip view 横向滚动；`wantsPeriodicDraggingUpdates()` 保持静止指针下的更新。`RequestLogDisplayOptionsEditor.contentDropTarget` 将实际指针位置转换到表格，用 `row(at:)` 解析目标行，悬停校验与释放接收共用这一解析入口。行内命中先用 `pointerX - grabOffsetX + dragWidth / 2` 得到拖拽图像中心，再按排除源字段后的稳定内容顺序与固有宽度生成各候选插槽中心，以相邻中心的中间分界选择插槽；不读取正在动画或占位的 frame，使宽首项在前后插槽间使用一致规则。无效目标或离开时清除目标占位；取消、拖动结束、重新加载或切换列时恢复源字段排版。占位高度参与目标行的临时高度计算，避免在空行中裁切；普通布局保留同一目标位置的在途动画，结束时仅移除本次拖拽拥有的动画键。列与整行拖动通过 `rowInsertionIndex` 将实际指针转换到目标表格，按目标行 `midY` 上／下半部决定前／后插入位置，继续使用原生 `.above` 插入反馈。

`RequestLogDisplayOptionsEditor` 持有布局草稿，编辑只刷新表单与整体预览；“应用”完成字段校验后通过 `RequestsViewController` 更新共享日志配置、保存应用偏好并刷新列表，“取消”直接放弃草稿。“恢复默认”仅替换草稿中的列和内容布局，仍需应用后生效，不清除按列标识保存的宽度。无效字段显示错误并禁用应用。预览冻结打开时最多三条记录，无记录时仅在预览中使用示例数据；复用 `RequestRecordsTable` 的只读预览模式，不修改记录、设备别名或真实列宽偏好。预览保留所有草稿列标题，包括空列和局域网关闭时的设备列；内容仍按字段有效性、局域网开关及空值规则提取。

`RequestmanCore.RequestLogDisplayOptions.layoutColumns` 提供物理列布局。`RequestLogLayoutColumn` 保存稳定列标识、标题与有序 `RequestLogLayoutLine`；每行包含有序 `RequestLogLayoutContent`，独立保存字段、来源、名称、水平对齐、行内垂直对齐和空值策略。每个内容实例独立保存 `appearance: RequestLogContentAppearance`，其 `presentation: RequestLogContentPresentation` 的编辑入口提供 `.plainText`、`.roundedRectangleTag`、`.capsule` 三项，分别为纯文字、圆角标签与胶囊；保存的旧 `.automatic` 值保持兼容，通过 `effectivePresentation` 按 `.plainText` 显示。字体、字重、省略、语义色和各字段专属外观均通过明确类型的属性保存；切换字段保留外观配置。旧布局缺少 `appearance`，或外观缺少新增属性时按对应默认值解码，保留现有列、行与字段。`RequestLogContentField` 提供标准字段、Header／Query 等字段及重放／错误信息；`ruleGroup`、`rule` 可分别配置，`rules` 将规则组与规则整体呈现。默认规则布局仍为规则组首行、规则第二行，也可放在同行或不同物理列。AppKit 只编辑配置并显示 Core 生成的文本，不操作捕获服务。

`RequestLogContentAppearanceEditor` 位于右侧空值配置下方，使用原生下拉框、复选按钮和数值输入编辑当前内容的外观；变更更新布局草稿与整体预览，应用后使用同一配置渲染实际日志。通用选项包括呈现方式、字体、字重和省略位置；`.none`“不省略”使用原生 cell 的 `.byCharWrapping`，纯文字、圆角标签、胶囊及设备内容均按实际分配宽度换行，无空格的长 URL 也可完整显示，并相应增加行高；字段专属选项包括方法／状态语义色、状态说明与异常强调、URL 主机强调、秒／毫秒时间精度、耗时单位与小数精度、慢请求着色及阈值、规则分隔符、Header／查询参数重复值单行或多行与数量提示。慢请求阈值仅接受 1–3600000 毫秒，无效草稿显示错误并禁用应用。普通标签和日志设备胶囊不采用玻璃样式；Inspector 的设备按钮保留既有样式。 `RequestLogValueCell` 仅调整原生标题区域和尺寸，仍由 AppKit 绘制按钮：圆角标签与胶囊共用相同的紧凑内边距，相对系统默认左右每侧减少 4 pt、上下每侧减少 1 pt；呈现切换只改变 `borderShape`，不更换按钮样式、文字颜色或字体。实际渲染与换行测量共用此 cell，Inspector 不应用这项内边距调整。外观只影响显示，原始捕获数据保持不变；Core 生成的共享文本同时用于显示、搜索及日志筛选保存。

布局保存到应用偏好，配置导入后同步恢复；标题与字段变化不改变列身份，列顺序和列宽按稳定标识保存。新列使用独立 UUID 标识，列宽不依赖数组下标；隐藏列不参与空间分配或拖动补偿。旧标准列开关、独立额外字段和合并关系迁移为对应物理列和行内内容；旧合并链保持最终目标，删除或循环的无效目标仍按原有独立列语义迁移。旧请求方法缺省配置继续按 URL 开关恢复，单个 Header 固定 UUID、旧 Header／环境列宽与六列宽度偏好继续兼容。

Header 支持原始请求、发出的请求、原始响应、返回的响应，分别读取 `requestHeaders`、`sentHeaders`、`receivedHeaders`、`responseHeaders`；名称按 HTTP 字段名校验并忽略大小写匹配。查询参数、URL、主机、路径、方法只支持原始请求／发出的请求，后者须有实际发出请求的记录；状态码只支持原始响应／返回的响应。所有字段不回退到其他阶段。查询参数按 URL 解码后的名称区分大小写匹配，保留重复参数顺序、空值与无等号参数，`+` 保持字面含义；路径保留百分号编码。截断 URL 不用于推断完整值，重复值按捕获顺序保存，悬停提示逐行保留值。

每项内容的 `RequestLogEmptyBehavior` 默认为 `hide`；没有可显示的值时不生成内容，也可选择 `customText` 使用用户填写的文字。一行没有任何可见内容时，不生成对应的 `RequestLogRenderedLine`。各单元格只排版实际可见行，整个行组始终垂直居中；内容的垂直对齐只影响其所在行内的位置。`NSTableView` 按同条记录各列的实际内容高度调整行高，下限为 56 pt。Header／查询参数的多行重复值及规则换行分隔通过 `RequestLogRenderedContent.displayText` 拆分显示，自动换行的高度同样计入度量，单元格的可见行组仍整体垂直居中。整体预览与日志列表共用原生文本及普通标签渲染，长文本可省略但保留完整悬停与辅助功能内容；配置变化刷新既有单元格及行高。

`RecordContentMeasurement` 用原生 `NSTextFieldCell`／`NSButtonCell` 的 `cellSize(forBounds:)` 按每项实际分配宽度度量所需高度，不为测量创建 View 层级；`RecordLineLayout` 同时供行高度量与实际内容排版使用，保持宽度分配一致。高度按各行内容最大高度累加，再加行间距和留白；表格行取各可见列最大高度。未变化记录且布局与列宽未变时复用缓存行高；列宽或显示配置变化后重新度量。

`RequestLogRow` 统一生成表格与搜索使用的最终可见行和完整文本。`CaptureRecordFilter.matches` 按当前布局匹配文本，再沿用资源类型、条件组和反向筛选逻辑；隐藏的缺失字段、无效字段和局域网关闭时的设备内容不参与搜索，自定义空值文字按实际显示内容匹配。`ExecutionHistoryModel` 持有共享布局配置，搜索上下文读取当前工作区规则名称与设备别名，列表和日志保存共用同一匹配入口；文件中的规则名称保留捕获快照。应用布局后同步刷新实时及打开文件中的记录，不改变捕获和结构化筛选条件，搜索不受列宽导致的文本省略影响。

验证范围为相关 Core 定向测试与必要 AppKit 静态检查，覆盖来源提取、重复值、空值行为、空行收起、规则分开／合并、显示与搜索一致性、旧配置迁移以及列身份与顺序恢复。不运行 UI 测试；配置表单、整体预览、表头拖动、行内对齐和自适应行高的实际运行效果仍待人工确认。
