# 请求修改配置（2026-09-26）

采用用户选定的方案 1，并合入 URL / Host 匹配与脚本 API 补充；[修订设计稿](request-modification-v3.png) 使用内置 Image Gen 生成。设计稿为布局参考，当前实现的控件外观由 macOS 系统绘制，执行契约以下文为准。

## 窗口和编辑

左侧以项目分组，项目名称和条目数在组标题，请求修改显示名称、方法和匹配值，停用条目降为次要视觉。底部保留原生圆形加号和搜索；加号继续提供添加请求、添加项目。中间是名称/启用、匹配条件，以及并排的请求阶段和响应阶段。步骤可拖动排序，也可在详情中上移、下移、停用和删除。

匹配条件按请求方法、地址和 Header 分组，组间使用系统分隔线。每个阶段的步骤列表与添加菜单共用浅灰圆角边框；步骤使用独立淡灰圆角背景。选中步骤使用浅蓝背景、细蓝边框和左侧蓝色标记，文字保持正常前景色；这部分按确认的设计设置，不采用列表默认的实色选中高亮。列表保留拖动排序、上下方向键选择、原生按钮可访问性与右键操作。

点击任一步骤后使用 `WorkspaceSplitController` 的窗口级原生 Inspector，标题为“步骤详情”，由标题栏最右侧按钮收起或重开。手动收起保留步骤选择；删除或切换到没有有效步骤的条目后关闭。请求日志继续使用同一分栏容器，但显示请求详情和日志专属工具栏，不显示步骤操作。

匹配区域参考 Finder 搜索条件，顶部标明“满足以下所有条件”，原生 `NSBox` 内按请求方法、URL / Host、Header 分为三组，以系统分隔线分开。方法独占第一行；地址目标、条件与值位于第二组同一行；Header 作为第三组独立开关。地址目标下拉宽 130 pt，条件下拉宽 90 pt，方法下拉宽 105 pt；方法与地址条件下拉的左侧对齐；字段保留原生交互。普通说明移至悬停提示，仅无效输入显示行内错误。Header 名称保留 240 pt，常规宽度下名称、条件和值同排，窄窗口在该组内换行，匹配值至少保留 100 pt。

步骤卡片固定 56 pt 高，序号、文字和停用图标垂直居中；标题与摘要各一行，截断内容通过系统悬停提示查看。选中时左侧蓝色竖线跟随卡片全高，并沿卡片圆角裁切。列表每项上下各留 4 pt，不另加行间距或垂直内容边距，列表高度按相同尺寸计算，超过 400 pt 后滚动。

Header 步骤命名为“添加或覆盖 Header”：不存在时添加，存在时按不区分大小写的名称覆盖，同名多项替换为一项。菜单、步骤标题和详情共用该名称，详情说明上述行为；序列化标识仍为 `setHeader`。添加或覆盖、移除步骤采用可编辑的原生 `NSComboBox`，可以从候选列表选择，也可输入完整自定义名称。候选项来自浏览器扩展 `ModifyHeadersRuleDetail.tsx` 的 `COMMON_HEADERS`，macOS 所有 Header 下拉框按不区分大小写的字母顺序展示。`Content-Length`、`Host` 等候选仍保留以便两端列表一致，但选择后明确提示其由代理维护，执行时继续拒绝非法改写。参见 [Apple NSComboBox](https://developer.apple.com/documentation/appkit/nscombobox)。

## URL 修改步骤

请求阶段新增“修改查询参数”和“替换 URL 字符串”，与其他步骤按顺序作用于当前 URL，命中日志保留对应类型。两项复用步骤的 name/value 字段保存，支持环境变量与动态模板；响应阶段不提供这两项。

- 修改查询参数：配置参数名称和值。名称区分大小写，不存在时追加，已存在时在首个位置覆盖，同名重复项合并为一项；值为空表示空值，保留 `name=`。名称和值按 UTF-8 URL 编码，未修改参数的原始编码、顺序和重复项保持不变。`+` 视为加号，与详情解析一致。
- 替换 URL 字符串：配置查找字符串和替换值，区分大小写，按原文替换全部匹配，不使用正则；查找字符串不能为空，替换为空会删除匹配内容。未匹配时保持 URL 不变。

两项完成后校验最终 HTTP/HTTPS 地址；无效结果报错，不写入当前 URL，也不计入成功执行步骤。步骤卡片展示参数赋值或替换关系。Core 测试覆盖编码、重复项、执行顺序、模板、保存恢复与失败；回环代理测试检查上游实际收到的路径和日志中的最终 URL，不能代替浏览器验收。

## 匹配

匹配目标仍为 URL / Host 二选一；Header 是独立、可启用的附加条件。勾选 Header 条件后，依次填写名称、独立的匹配规则和值，名称输入框宽 240 pt，匹配值使用剩余空间，窄窗口在 Header 组内换行；地址条件、Header 条件和 HTTP 方法必须同时满足才命中。例如 URL 等于某个地址，并且 `X-Environment` 等于 `staging`。关闭 Header 条件时仅按地址与方法匹配，保留已填写的 Header 配置；隐藏的输入控件仍保留布局空间，避免改变窗口和分栏宽度。

Header 支持等于、包含、通配符和正则，匹配客户端原始请求头，在修改步骤之前执行。名称不区分大小写，值区分大小写；缺失时不命中，同名多项中任意一项符合即可，不拼接值。启用时，非法或空名称、空匹配值和无效正则不会命中，并在编辑器提示。流程预览使用“请求与响应输入”中的请求 Header，与代理采用同一联合匹配逻辑。

Header 条件独立保存为 `matchHeaderEnabled`、`matchHeaderName`、`matchHeaderRule` 和 `matchHeaderPattern`。旧配置缺少字段时默认关闭，不影响 URL / Host 匹配或旧前缀迁移。此前保存的 Header 单独匹配配置会迁移为 URL 通配符 `*` 加原 Header 条件，保留原有行为，之后可进一步限定地址。

| 配置 | 行为 |
| --- | --- |
| 目标 | URL 匹配：完整绝对 URL；Host 匹配：解析后的主机名，不含协议、端口、路径、查询参数 |
| 通配符 | 整体匹配，`*` 为任意长度、`?` 为一个字符；其余字符按字面量处理 |
| 正则 | ICU 正则搜索，可使用 `^` / `$` 限定范围；无效表达式在编辑器显示错误、不命中 |
| 等于 / 包含 | 字符串全等 / 子串匹配 |
| 大小写 | URL 区分大小写，Host 不区分大小写并去除末尾域名点 |
| 方法 | 全部，或指定 HTTP 方法；多个命中仍按项目顺序选择首个启用流程 |

不再提供前缀选项。空匹配值不命中。旧 `urlPrefix` 解码为 URL 正则 `\A` + 转义后的原值，保留旧配置的字面量前缀语义（包括 `?`、`*` 等字符）。工作区保存版本提升为 2，加载接受 1 和 2；旧版本 App 会拒绝版本 2，避免静默覆盖新字段。

## 脚本 API

两个阶段的“添加步骤”均包含“执行脚本”。代码为同步 JavaScript 函数体，请求阶段必须返回 `request`，响应阶段返回 `response`（也可返回具有同样结构的新对象）。脚本不作模板展开，环境变量通过 `env.name` 读取。

```ts
type Header = { name: string; value: string };
type Request = {
  method: string;
  url: string;
  headers: Header[];
  body: string | null;
};
type Response = {
  status: number;
  headers: Header[];
  body: string | null;
};
// 每次执行注入：
request: Request;
response: Response | null;
env: Record<string, string>;
```

请求阶段 `request` 是之前步骤处理后的请求，`response` 为 `null`。响应阶段 `request` 是只读的发出请求快照，`response` 是之前步骤处理后的响应。`env` 始终只读。Header 使用数组，保留大小写与重复项（例如多个 `Set-Cookie`）；比较名称时忽略大小写。

`body` 为完整 UTF-8 文本，JSON 也以字符串提供，使用 `JSON.parse` 和 `JSON.stringify` 处理。gzip / zlib-wrapped deflate 在后台解码；不支持的编码、损坏压缩或非 UTF-8 内容为 `null`。空正文是 `""`。返回 `null` 保留已有正文，返回空字符串清空正文；仅当文本实际改变时替换正文并清除原编码、摘要、范围与缓存校验 Header，代理重建 Content-Length / Transfer-Encoding。未修改的压缩和二进制正文原样转发。

```js
// 请求阶段
request.headers.push({ name: "X-API-Key", value: env.apiKey });
return request;

// 响应阶段
const data = JSON.parse(response.body);
data.debug = true;
response.body = JSON.stringify(data);
return response;
```

`method` 不支持 CONNECT / TRACE，`url` 必须为无用户信息及片段的完整 HTTP/HTTPS 地址，`status` 为 200–599 整数。Host、Content-Length、Transfer-Encoding、Connection、Upgrade、Trailer 可读取但不能由脚本改写。所有返回字段校验成功后才提交草稿，失败不会部分提交脚本结果。

“API 帮助”在编辑器内展示相同结构、格式和示例。“示例输入”可编辑请求 URL、方法、Header JSON 数组、请求文本，以及响应状态、Header、文本；“试运行”使用当前环境和真实脚本执行器，显示 JSON 结果或错误，不发送请求。“预览流程”另校验真实测试 URL 是否命中，再按顺序执行两阶段。

## 执行与验证边界

使用系统 [JavaScriptCore](https://developer.apple.com/documentation/javascriptcore/jscontext) 和一次一脚本的独立进程；App 同一可执行文件通过专用参数进入工作模式，在创建 NSApplication 之前返回，SwiftPM 测试使用独立 worker target。没有导出原生对象、文件、网络、DOM、Node.js API 或定时器；不支持 Promise 返回值。

脚本默认 1000 ms，可设 50–5000 ms。请求事务仍为 30 秒。取消和事务时限传到解码器、步骤循环和工作进程；工作进程每 25 ms 检查取消，超时/取消可强制终止。代理全局最多 4 个脚本流程，试运行和真实脚本共用最多 4 个工作进程名额，满时报告错误，不堆积无界等待任务。正文、Header、脚本和匹配字符串没有新增应用层尺寸上限，沿用[当前限制策略](../LimitsAudit.md)。

脚本所在方向等待完整 Body 后执行；没有脚本的方向保留现有流式路径。持续流（例如 SSE）不适合完整 Body 脚本，可能到达事务超时。脚本失败停止流程，请求阶段返回 400、响应阶段返回 502，并记录具体错误；尚未实现设计稿中的可选失败后继续策略。本轮支持同步脚本，辅助 HTTP API 和异步脚本仍为后续能力。

回归覆盖 URL/Host 四类匹配、旧前缀迁移、JSON 返回格式、重复 Header、空/null Body、大正文、死循环超时和取消，以及 TCP 回环真实请求/响应、Mock、分块上传、编码正文。工作区隐藏窗口检查覆盖分栏、标题、工具栏、收起重开和切页；不代表完整 App 的视觉或 Chrome 实测验收。
