# HTTP/2 捕获与修改

实现日期：2026-09-28。覆盖 HTTPS 解密后的 HTTP/2，外层显式代理仍使用 HTTP/1.1 CONNECT。适用于全局接管、浏览器与仅启动代理模式，包括已开启局域网接入的客户端。

## 同协议契约

客户端与 Requestman 的 TLS ALPN 可协商 `h2` 或 `http/1.1`。浏览器的 ClientHello 同时提供两种协议时，先与 CONNECT 目标完成上游 TLS 协商和信任校验，再仅向浏览器提供上游选定的协议；目标没有 ALPN 时选择 HTTP/1.1。这样只支持 HTTP/1.1 的站点不会被代理提前选成 HTTP/2。协商好的上游连接交给首个同目标、同出口的请求复用，不额外探测后重连。客户端仅提供一种协议时保留原有严格路径。

协议选定后，上游只提供客户端当前使用的协议，不做 HTTP/2 与 HTTP/1.1 转换，不在失败后更换协议或自动重发请求。规则改写目标后仍遵守同一协议要求。ALPN 的协议列表与选择语义见 [RFC 7301](https://www.rfc-editor.org/rfc/rfc7301.html#section-3)。

| 客户端 | 上游 | 行为 |
| --- | --- | --- |
| HTTP/2 | ALPN 为 h2 | 正常捕获、修改和转发 |
| HTTP/2 | http/1.1、没有 ALPN 或协商失败 | 明确失败；业务请求不按 HTTP/1.1 发送 |
| HTTP/1.1 | HTTP/1.1 | 沿现有路径处理 |
| HTTP/1.1 | 仅支持 HTTP/2 | 保留协议或服务器失败；不尝试 HTTP/2 |

HTTP/1.1 上游没有 ALPN 时沿用 HTTP/1.1，这是旧服务器的常规接入方式；若对端不能处理，直接失败。HTTP/2 必须明确协商为 `h2`。TLS 信任与目标主机名继续由系统 Security 校验，测试只使用内存锚点。HTTP 上游（如 Surge）先完成外层 CONNECT，再在隧道内与目标协商同协议。

本地 Mock 按客户端协议返回，不发送上游业务请求。双协议浏览器须先建立上游 TLS 才能选定协议，此时还无法读取加密的请求路径或匹配 Mock；因此这类连接即使命中 Mock 也需要目标可达且证书可信。单协议客户端仍在规则决定转发后才建连，Mock 可完全跳过上游。证书未就绪、未启用目标域名解密时继续 CONNECT 透传，不声称已捕获内部 HTTP/2。明文 HTTP/2（h2c）、HTTP/2 代理入口、Server Push、跨域连接合并、HTTP/3、gRPC 专用解析及 WebSocket Extended CONNECT 不在本轮范围；上游关闭 Server Push，WebSocket 保留原 HTTP/1.1 Upgrade 路径。

## 请求与连接生命周期

`ClientHelloALPN` 只读取解密目标的首个 ClientHello 中公开的 ALPN 列表，支持 TCP 分片和跨 TLS record 的握手分片，等待阶段缓冲上限 256 KiB；完整 TLS 校验仍由 NIOSSL 负责。服务端 TLS context 缓存同时区分叶证书 DER 与协议列表，防止相同证书复用到错误协议。预先建立的上游连接保留提前收到的 TLS 应用数据，未被请求采用时 30 秒关闭，客户端关闭及停止捕获也会释放。

`swift-nio-http2` 提供 HTTP/2 帧、HPACK、流状态机及两级流控。下游 TLS 协商完成后建立流复用器，每个子 Channel 安装独立 `ProxyConnection`，复用现有事务协调器、规则匹配、双阶段 Processor、脚本/JSON、延迟、Body 采集和 SSE 存储。HTTP 消息适配器只用于复用内存消息类型，不在网络上转换成 HTTP/1.1。

`ProxyHTTP2Session` 按客户端连接持有上游连接，按目标与出口区分，不跨客户端共享。并行 stream 共用相同目标的上游 TCP/TLS 连接；每个 stream 单独拥有请求、规则/环境快照、日志与取消状态。停止捕获关闭所有物理连接及请求流。单个请求取消、步骤失败或 SSE Body 替换只关闭对应 stream，不能关闭其他请求使用的连接。

每条下游 HTTP/2 连接声明最多 100 个并发流；每个上游连接最多接纳 100 个活跃/等待 TLS 的请求，满时明确失败。物理下游连接仍受已有 256 条上限约束。父连接继续读取 HTTP/2 控制帧，子 Channel 按写入完成和消费情况拉取正文；NIO 管理连接与 stream 窗口，不在单个慢流上暂停整个 socket。没有新增正文尺寸或截断限制。

收到 GOAWAY 后该上游连接不再接收新请求，已建立流由 NIO 按 GOAWAY 边界处理；仅后续新请求建立新连接，既有请求不会自动重放。无活跃流的下游/上游连接 30 秒后关闭；TCP 建连 5 秒，CONNECT 与 TLS 协商 30 秒，HTTP 事务仍无总时限。空闲和退役的上游从会话映射移除。

## 消息与日志

请求方法、URL 和状态码继续使用结构化字段，伪 Header 由协议适配器生成。HTTP/2 不发送 Connection、Keep-Alive、Upgrade 或 Transfer-Encoding 等连接专用 Header。重复 Header 保留；未替换正文时转发 HTTP/2 请求及响应 trailers，替换正文时不保留与原正文绑定的 trailers。HTTP/2 正常 END_STREAM 与取消分别处理，不能将正常自动关闭的 stream 误记为正文不完整。

`CaptureRecord.clientHTTPVersion`、`upstreamHTTPVersion` 分别记录客户端和实际使用的上游版本；上游尚未建立或本地 Mock 时后者为空。详情摘要显示两侧版本。原始/发出请求与收到/最终响应的 trailers 分别保存在 `requestTrailers`、`sentTrailers`、`receivedTrailers`、`responseTrailers`，与协议版本一起进入日志归档；旧日志缺失这些可选字段时仍能打开。

从 HTTP/2 记录直接或编辑后重放会保留 HTTP/2，通过本地 CONNECT + TLS + HTTP/2 重新进入代理规则与记录链路。要求当前目标启用 HTTPS 解密且证书已配置；不满足时明确失败，不转换为 HTTP/1.1。历史记录没有协议字段时按原有 HTTP/1.1 行为重放。

## 验证

`HTTP2IntegrationTests` 使用真实 TCP/TLS 回环和临时内存 CA，覆盖直连/HTTP 上游、多路复用、单流取消、大正文流控、请求/响应 trailers、脚本与 JSON 修改、Mock、SSE 与普通请求并行、SSE 替换只取消单流、GOAWAY 后新请求建连、停止捕获、同协议重放与来源关联、协议字段归档，以及不进行跨协议回退。额外覆盖浏览器双协议 offer、目标同时支持两种协议时的偏好、无 ALPN 目标、只提供 HTTP/1.1 的客户端、协商期证书校验失败和 Mock 不发送业务请求。`ClientHelloALPNTests` 覆盖握手与 TCP 分片、畸形长度及 ALPN、服务端 context 的协议隔离。既有 HTTPS、HTTP/1.1、SSE、WebSocket 与日志归档使用相关定向回归。

这些验证不代表真实 Chrome、手机、Surge 或完整 App 运行验收；本轮不运行 UI 测试、不构建部署 App。
