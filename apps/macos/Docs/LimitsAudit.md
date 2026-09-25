# macOS 限制检查（2026-09-26）

范围：当前工作区的 macOS Core、代理、证书与请求详情；不包含独立浏览器扩展。以下为源码与自动检查结果，不代表真实 App 或浏览器验收。

## 已移除的限制

| 范围 | 当前行为 | 代码 |
| --- | --- | --- |
| 日志 URL / Header | URL、Header 名称、值和全部字段完整保留，原始/最终请求与响应一致；不再做 2,048/128/256 字符或 40 个字段截断 | [CaptureRecord.swift](../Packages/RequestmanCore/Sources/RequestmanCore/CaptureRecord.swift) |
| 凭据 | Authorization、Proxy-Authorization、Cookie、Set-Cookie、X-API-Key 和其他 Header 均保留实际值；详情比较、筛选和 cURL 导出不再使用脱敏占位符 | [RequestCURL.swift](../Requestman/Features/Requests/RequestCURL.swift)、[CaptureRecordFilter.swift](../Packages/RequestmanCore/Sources/RequestmanCore/CaptureRecordFilter.swift) |
| 环境变量 | 编辑器直接显示值，移除隐藏值开关和 SecureField | [EnvironmentsView.swift](../Requestman/Features/Environments/EnvironmentsView.swift) |
| Body 采集 | 完整采集各方向实体字节；移除单份 64 KiB、共享 32 MiB 预算；断流继续标记未完成 | [CaptureBodySnapshot.swift](../Packages/RequestmanCore/Sources/RequestmanCore/CaptureBodySnapshot.swift) |
| 模板与正文修改 | 移除模板/展开结果 1 MiB、生成正文共享 16 MiB 预算和 Header 修改后 32 KiB 校验 | [WorkflowEngine.swift](../Packages/RequestmanCore/Sources/RequestmanCore/WorkflowEngine.swift)、[LocalProxyServer.swift](../Packages/RequestmanCore/Sources/RequestmanProxy/LocalProxyServer.swift) |
| 网络 Header | 请求与上游响应解码器的字段大小、列表大小和字段数显式设为 Int.max；移除应用原设 32 KiB / 128 字段上限。请求头跨多次读取时继续读取剩余部分 | [LocalProxyServer.swift](../Packages/RequestmanCore/Sources/RequestmanProxy/LocalProxyServer.swift) |
| 预读 Body | 移除建连前预读缓冲 64 KiB 字节上限 | 同上 |
| 解压 | 移除输入/输出 256 KiB 与 8 层编码上限；按块向 zlib 提供输入，避免大 Data 转换为 32 位长度时溢出 | [RequestBodyDecoding.swift](../Requestman/Features/Requests/RequestBodyDecoding.swift) |
| JSON | 移除应用层 256 KiB、64 层、4,096 节点限制；普通 Body 和字符串 JSON 预览共用 Foundation 解析器，仍校验合法性并响应取消 | [RequestInspectionData.swift](../Requestman/Features/Requests/RequestInspectionData.swift) |
| 通用执行器 Body | 移除单 Body 4 MiB、共享缓冲 64 MiB 及预算预留；按传输块读取到 EOF，缓冲由对象生命周期持有 | [BodyPreparation.swift](../Packages/RequestmanCore/Sources/RequestmanCore/BodyPreparation.swift)、[ExecutionLimits.swift](../Packages/RequestmanCore/Sources/RequestmanCore/ExecutionLimits.swift) |

未增加替代内容上限或新的内存预算。没有改变 HTTP 语法校验、完整性判断、取消传播、传输分块与写完成后的拉取机制。cURL 仍由 curl 重建连接与传输分帧，不把逐跳代理认证 Header 当作目标服务器 Header 重放。

## 仍保留的限制

| 范围 | 当前行为 |
| --- | --- |
| 并发 / 队列 | 实际代理最多 256 个连接（含 CONNECT）；建连前队列最多 128 个 HTTP part。通用执行器默认活跃 16、等待 32，尚未接入当前 NIO 转发 |
| 网络读取 | socket 每次读取 16 KiB、每轮一个消息；通用 BodyReader 默认单块 64 KiB。这些是读取分块大小，不是正文总大小 |
| 时限 | TCP 建连 5 秒、请求事务 30 秒、keep-alive 空闲 30 秒、透传 CONNECT 读空闲 120 秒；启动前上游探测默认 3 秒 |
| 日志容量 | 待读取队列 256 条、每批 64 条；界面历史 500 条、200 ms 拉取一次；旧记录淘汰，不落盘 |
| 显示元数据 | 项目/工作流/环境/规则名 128 字符；错误 512 字符；步骤摘要 64 条、每条 128 字符；命中动作快照 128 条。均不用于截断实际 URL、Header 或 Body |
| 流程 | 首个匹配流程胜出；每方向最多 64 个步骤；请求 Mock / 重定向后进入响应流程 |
| Header 操作语义 | 设置 Header 替换全部同名项；Host、Content-Length、Transfer-Encoding、Connection、Upgrade、Trailer 由代理维护 |
| 协议 | 内容处理仅 HTTP/1.1；不支持流水线、协议升级/WebSocket、TRACE；未配置证书时 HTTPS 仅 CONNECT 透传 |
| 缓存 | 树视图状态 24 份；站点证书与 TLS context 各 128 项；CA 信任检查最多缓存 5 秒 |
| 导出完整性 | 未采集/断流、外部标记不完整数据、CONNECT、带正文 HEAD、重复 Host、无法可靠导出的字符仍会禁用对应 cURL 导出 |

## 验证

核心、证书与 TCP/TLS 回环测试覆盖完整凭据、超过旧限制的 URL/Header/正文及既有流程。新增边界样例包括：100 KB Header、150 个附加字段、2 MiB 静态响应、33 MiB 正文采集、5 MiB 通用 BodyReader、超过 256 KiB 的解压输出与跨多块压缩输入、1 MiB JSON、128 层嵌套、5,000 个节点。

详情和 cURL 脚本验证修改前后完整复制、凭据值比较与长值筛选，宿主通过 Swift 6 类型检查；未构建或启动 App，未进行真实浏览器流量验收。

## 同步脚本补充（2026-09-26）

脚本没有新增 Body/Header/源码或匹配字符串的大小上限。保留执行时限：脚本默认 1000 ms，可配置 50–5000 ms，并受事务 30 秒限制；取消会终止工作进程。脚本流程与工作进程各最多 4 个，满时明确失败；正则匹配通过 ICU progress 回调在 20 ms 后取消搜索。数据结构和转发语义见[请求修改配置](Design/request-modification.md)。
