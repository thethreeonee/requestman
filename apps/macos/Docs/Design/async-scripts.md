# 异步脚本与辅助 HTTP

更新日期：2026-10-03。本契约适用于 macOS 原生 App；浏览器扩展的注入脚本不受本次改动影响。

## 脚本与返回值

脚本作为 JavaScript `AsyncFunction` 的函数体运行，可以直接使用 `await`、Promise 与 `Promise.all`。已有 `return request` / `return response` 脚本继续工作。`env` 深层只读；响应阶段的 `request` 是只读发出快照。请求和响应的数据结构、Body 文本与传输 Header 约束沿用[请求修改配置](request-modification.md#脚本-api)。

只有 Promise 成功完成、结果在 worker 内序列化并通过宿主完整校验后，才提交本步骤的草稿。异常、取消、超时或无效返回值不会提交本步骤的部分修改；此前成功步骤仍保留。

```js
const tokenResponse = await fetch(env.tokenURL, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ key: env.apiKey })
});
if (!tokenResponse.ok) throw new Error(`Token HTTP ${tokenResponse.status}`);
const token = await tokenResponse.json();
request.headers.push({ name: "Authorization", value: `Bearer ${token.access_token}` });
return request;
```

## fetch 子集

`fetch(url, init?)` 接受完整 HTTP/HTTPS URL 字符串；支持 `method`、`headers`、`body`、`redirect` 与 `signal`。不支持用户信息、片段、CONNECT / TRACE / TRACK、GET / HEAD 正文。Host、Content-Length、Transfer-Encoding 等传输字段由宿主生成。文本正文默认 Content-Type 为 `text/plain;charset=UTF-8`，二进制正文接受 ArrayBuffer 或 TypedArray/DataView。

| 对象 | 支持 |
| --- | --- |
| Headers | 对象或二元数组初始化；append / set / delete / has / get / getSetCookie；entries / keys / values / forEach 与迭代 |
| fetch Response | status / statusText / ok / url / redirected / headers / bodyUsed / type |
| 正文读取 | 异步 text() / json() / arrayBuffer()，正文只能消费一次 |
| 取消 | AbortController.abort(reason?)，AbortSignal 的 aborted / reason / throwIfAborted / abort 事件 |
| 重定向 | follow（默认）、error、manual；follow 最多 20 跳 |

响应头到达就 resolve fetch；只有调用正文读取方法才将正文传入 worker。4xx / 5xx 正常 resolve，调用者检查 `ok` / `status`；网络、TLS、解码或取消错误拒绝 Promise。正文支持 gzip 与 zlib-wrapped deflate 解码，text() 按 UTF-8 解码，json() 再解析 JSON。HEAD 与无正文状态返回空正文。日志保留接收到的原始编码字节。

301 / 302 将 POST 改为 GET，303 将非 GET / HEAD 改为 GET，并清除正文及相关 Header；307 / 308 保留方法和正文。跨 origin 清除 Authorization、Proxy-Authorization、Cookie。manual 返回实际 3xx 及可见 Location；该原生客户端没有浏览器的 opaque / CORS 响应语义。

未知 init 选项明确拒绝。FormData、Blob、URLSearchParams 正文、流式上传/读取、Response.clone()、Request / Response 构造器、定时器、DOM、Node.js、AbortSignal.timeout/any 不在本次 API 范围内。没有共享浏览器 Cookie，也不自动维护 Cookie jar。

## 执行与资源

每次脚本使用一个独立 JavaScriptCore worker。JSContext 始终由同一固定线程访问，RunLoop 推进宿主回调与 Promise；同步死循环、Promise 永不完成、返回值序列化死循环都能通过终止进程结束。

stdin / stdout 使用版本 1 的长度分帧 JSON RPC，stdout 只承载协议。大消息分片，每片最多 16 KiB；响应元数据与正文分开，正文分块传输。宿主等待分块写完成，worker 每次只接纳一个 RunLoop 回调；fetch 提交与取消确认也有准入额度，避免同步循环无限积累 RPC。输入、输出和解码仍需要有限完整数据，不设新的正文截断上限。辅助响应先写权限 0600 的临时文件，网络读取等待磁盘写完成；完成或取消后清理临时文件。

新建脚本默认 10000 ms，可配置 50–60000 ms。旧工作区及导入脚本保留显式时限，缺少 scriptOptions 的旧数据继续使用 1000 ms。时限涵盖 worker 启动、脚本计算和辅助网络等待；HTTP 事务和流程预览仍无总时限。

脚本流程最多 4 个，worker 最多 4 个，满额明确失败。每个 worker 的辅助操作最多 4 个执行、32 个等待；宿主网络全局最多 8 个执行、64 个等待，额度独立于主请求。排队取消会移除等待项并释放名额。

脚本完成、异常、超时、取消或 worker 退出会取消尚未结束的辅助请求。主客户端断开及停止捕获沿事务传递取消，停止捕获同时关闭注册的辅助连接。已经发送给服务器的副作用无法撤销。

## 出口、TLS 与记录

宿主 `ScriptHTTPService` 在事务创建时固定连接配置，两个阶段共享该服务。直连遵循系统网络路由；配置 HTTP 上游时，HTTP 使用 absolute URI，HTTPS 经 CONNECT 后 TLS。使用现有 NIO HTTP/1.1、TLS 握手与 SecTrust 主机名校验，不读取系统代理指向自己的配置、不经过本地代理监听或普通规则匹配。辅助网络本次仅使用 HTTP/1.1。

明确指向自身监听地址或解析到本地监听的 URL 被拒绝，重定向也重新检查。辅助流量注册到捕获会话，停止时统一关闭。服务绑定会话身份，停止后即使重新启动捕获，旧服务也不能向已退出的 EventLoop 提交请求。

每次 fetch 对应一条辅助日志，通过 `auxiliaryParentID`、`auxiliaryStepID`、`auxiliaryCallID`、`auxiliaryExecutionID` 关联父事务、步骤、调用与脚本执行。父请求详情的“辅助请求”菜单可定位子记录，辅助详情显示状态并可跳回仍在日志中的父请求。重定向记录最终 URL 与发出快照；日志文件保留关联字段，旧日志文件继续可读。清空后迟到更新不会恢复旧记录。

## 试运行与真实联调

单步“运行”和“运行预览”默认离线，使用真实脚本执行器与样例输入，fetch 明确报错。“真实联调”是单独的原生按钮，只有捕获运行时可获取宿主服务，只发送脚本辅助请求；主请求与响应仍为样例，不向主 URL 发出请求。

真实联调日志保留步骤、调用和执行关联，没有虚构父请求记录。修改样例、关闭窗口或切换步骤取消当前运行，迟到结果不能覆盖新输入。

## 验证边界

定向非 UI 测试覆盖 Promise 完成/拒绝、事务草稿原子性、重复 Header、正文一次消费、二进制与分块、Promise.all、Abort、超时取消、旧数据时限、真实 TCP/TLS 出口、CONNECT、信任及主机名、重定向、压缩、清空/停止、辅助日志和规则递归隔离。原生宿主通过源码引用检查与 Swift 类型检查验证。

这些检查不代表完整 App 界面、Chrome 页面加载、真实网站副作用或吞吐基准已验收。
