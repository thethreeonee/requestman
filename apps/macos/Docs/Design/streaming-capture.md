# SSE 与 WebSocket 持续捕获

## 范围

macOS 显式 HTTP/1.1 代理支持 SSE 事件观察和 WebSocket 基础消息观察。SSE 可来自 EventSource 或 fetch/POST；HTTP/2 Extended CONNECT、HTTP/3、逐事件/消息修改、消息注入及重放不在本轮范围。界面使用原生 AppKit 控件。

## SSE 配置与执行

界面不再提供 SSE 复选框。旧配置的 `RequestWorkflow.isSSE` 继续随工作区、复制和归档保存，但不参与代理执行路径判断；已有响应 Header 步骤保持可编辑。Connection、Content-Length、Transfer-Encoding 仍由代理负责。

收到上游原始响应头后，依据 `Content-Type: text/event-stream` 自动选择 SSE 执行路径，不要求勾选开关或请求携带 Accept。请求 Accept、请求 Content-Type、配置标记及后续响应 Header 修改均不将普通上游响应自动转换为 SSE；普通响应仍按原流程执行，Body 内容不自动包装为事件。Header 和状态步骤在发出响应前执行。延迟在头部阶段等待，不等待整个流结束。启用的替换 Body（文本、Base64、本地文件）或重定向步骤会取消主上游，执行响应流程并生成有限的替代响应；旧上游不再被消费到 EOF，取消原因写入记录，不能把旧流误标为完整。

整流响应脚本只有放在替换 Body 之后才可执行，此时处理的是有限替代内容。需要读取原始完整响应的脚本明确返回不兼容错误，避免无限等待；本轮不执行逐事件脚本。请求阶段及本地 Mock 沿用现有步骤语义。本地 Mock 声明 SSE Content-Type 时仍可记录其预设事件内容，但不因配置标记自动转换 Body。已识别的上游 SSE 经 Body 替换后，即使步骤更改 Content-Type，也保留替代内容的原始字节记录。

`SSEParser` 按 UTF-8 字节增量解析，覆盖 BOM、CR/LF/CRLF、跨块字符、多行 data、事件类型、持续 id、retry 和注释心跳。只有空行结束的完整事件进入事件列表，未完成片段保留在原始数据中。旁路解压支持 gzip/deflate，不改写转发字节；不支持的编码或损坏压缩流显示记录错误，网络仍原样转发。客户端负责重连，代理不主动重放请求或修改 Last-Event-ID。

## WebSocket

普通 Upgrade 与 CONNECT 内明文 Upgrade 均可接入 ws；CONNECT 内 TLS 根据当前 HTTPS 解密配置与证书可用性进入 wss 解密或不透明隧道。隧道入口仅观察协议前缀，保留并重放与 CONNECT 同批到达的字节；不会把明文 ws 当作 TLS。

双向 Upgrade 经过 HTTP end 后切换 pipeline，校验版本、Key/Accept、Connection、Upgrade 与子协议，保留与 101 同批到达的首帧。基于 NIOWebSocket 编解码，不再复用 HTTP keep-alive 连接。文本、二进制、分片、Ping/Pong、Close 按方向转发并记录，客户端发往上游的帧重新掩码。Ping/Pong 由端点处理，代理不另外注入心跳。

本轮从上游握手中移除 Sec-WebSocket-Extensions，明确不协商 permessage-deflate 或其他扩展；上游返回未经协商的扩展时拒绝升级。普通握手 Header 可修改，握手响应的 Body、状态和脚本步骤明确不支持。协议关键字段由代理维护，消息修改暂未接入。

活动 WebSocket 没有总时限或读空闲超时；收到 Close 后等待对端最多 5 秒，记录关闭状态码与原因。未完成关闭握手的断开与正常关闭分开，停止捕获关闭两端。NIO 帧上限显式设置为 UInt32.max，避免默认 16 KiB 限制；分片组装暂保留当前未完成消息，不增加应用层消息总长截断。

## 记录与存储

`CaptureRecord` 分离协议、连接生命周期和流程处理结果。HTTP 开始处理时创建记录，活动记录每 200 ms 按稳定 ID 合并快照；结束时更新原行。SSE 和 WS 内容经 `CaptureStreamStore` 保存到会话临时文件，内存只保留消息偏移索引及当前未完成事件/消息；主线程不读取整段流。

磁盘写入与 SSE 解析在独立串行队列执行，下一批网络读取等待当前转发写入和记录写入完成，不在 NIO 事件循环同步进行文件 I/O，也不为每个网络包创建 Swift Task。记录失败独立显示，不伪造网络失败或完整内容。未修改的 SSE 原始/最终事件共用存储，替代响应独立保存；WS 按收发方向区分消息。

暂停记录延续既有语义：暂停向历史列表发布快照，网络、规则和已建立流的内容采集继续。暂停前已显示的活动连接保留最新快照，恢复后更新；暂停期间已关闭的连接也会更新为终态。清空增加记录代次，旧连接不再写入或重新出现；旧存储在引用释放后清理。停止捕获保留已显示的会话记录供检查；记录淘汰、清空或关闭详情后释放其存储引用。临时内容不进入工作区归档，不提供跨启动的执行历史。

请求详情的「响应体」在 SSE 中显示为「事件流」、在 WS 中显示为「消息」。消息按每页 200 条读取，SSE 原始数据按每页 64 KiB 读取；这些是分页大小，不是内容上限。支持当前页搜索、复制、上一页/下一页和跟随最新。协议筛选为独立 SSE/WS 原生分段，原有资源分类保持原有间距，窄窗口分两行排列；筛选面板提供「仅活动连接」。WS 禁止导出普通 HTTP cURL；SSE 请求导出增加 --no-buffer；持续会话不生成误导性的完整 Mock。

## 验证

Swift package 测试覆盖 SSE 分块 UTF-8、行结束、ID、gzip/deflate、分页后继续写入、旧配置读取、Header 步骤幂等、记录合并、暂停后终态恢复与清空隔离，以及真实 TCP 上的无限 SSE、文本/文件 Body 替换、上游取消和首包延迟，并验证无需 SSE 开关的 Header/状态修改、POST 响应脚本边界、请求与响应 Header 不触发自动转换、替代 Body 保持字面内容。WebSocket 回环覆盖普通 Upgrade、明文 CONNECT、wss、HTTP 上游、握手首包、分片文本、二进制、控制帧、大于 16 KiB 的帧、关闭握手、无效 UTF-8、异常断开和主动停止。TLS 测试使用内存证书与测试锚点，不安装或信任本机证书。

隐藏 AppKit 窗口检查复选框、Header 插入、协议筛选、实时详情及原有界面回归。上述证据不代表完整 App 外观、Chrome 或 Surge 真实流量验收。
