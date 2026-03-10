# requestman

> 在 DevTools 里直接拦截和修改网络请求的浏览器扩展。

**requestman** 在浏览器 DevTools（Chrome & Firefox）中新增一个 **Redirect Rules** 面板。不需要配置代理，不需要改动代码，就能实时对网络请求进行重定向、改写、拦截和延迟。

---

## 🚀 安装

### Chrome

1. 打开 `chrome://extensions/`
2. 右上角开启**开发者模式**
3. 点击**加载已解压的扩展程序**
4. 选择 `dist/chrome` 文件夹

### Firefox

1. 打开 `about:debugging#/runtime/this-firefox`
2. 点击**加载临时附加组件**
3. 选择 `dist/firefox/manifest.json`
   - 或直接安装 `dist/requestman-firefox.xpi`

---

## 🎯 快速上手

1. 打开任意网页，按 `F12` 启动 **DevTools**
2. 切换到 **Redirect Rules** 面板
3. 点击**新建分组** → **新建规则**，选择规则类型
4. 填写匹配条件和对应动作
5. 确认规则、所在分组以及**全局开关**均已开启
6. 刷新页面或重发请求，验证效果

---

## 🛠 规则类型

### 1. 🔀 请求重定向（Redirect Request）

将请求从一个 URL 跳转到另一个 URL，也可以重定向到扩展内置的本地文件。

**适用场景：**
- 将生产环境的 API 请求转发到本地开发服务器
- 用本地构建产物替换 CDN 上的静态资源

**示例：**
```
匹配 URL 包含：  api.example.com/v1/users
重定向到：       http://localhost:3000/v1/users
```

---

### 2. ✏️ 字符串重写（Rewrite String）

查找并替换请求 URL 中的某段字符串。

**适用场景：**
- 不改代码直接切换 API 版本
- 批量替换请求中的域名或路径片段

**示例：**
```
匹配 URL 包含：  /api/v1/
将：             /api/v1/
替换为：         /api/v2/
```

---

### 3. 🔗 Query 参数（Query Params）

对请求的 URL 查询参数进行增加、修改或删除。

**适用场景：**
- 自动给所有 API 请求追加 `debug=true`
- 去掉 `utm_source` 等埋点参数避免干扰
- 强制覆盖功能开关：`feature_x=enabled`

**示例：**
```
匹配 URL 包含：  api.example.com
添加参数：       debug = true
```

---

### 4. 📤 改写请求体（Modify Request Body）

替换 POST/PUT 请求发送的请求体——支持静态文本或动态 JS 函数。

**适用场景：**
- 固定一个测试 payload 来复现 Bug
- 给每次表单提交自动注入额外字段

**静态示例：**
```json
{ "userId": 42, "role": "admin" }
```

**动态示例（JS 函数）：**
```js
function modifyRequestBody(args) {
  const body = JSON.parse(args.body);
  body.debug = true;
  return JSON.stringify(body);
}
```

---

### 5. 📥 改写响应体（Modify Response Body）

替换或转换服务端返回的响应内容——支持静态文本或动态 JS 函数。

**适用场景：**
- Mock 一个还没实现的接口
- 强制返回错误状态，测试页面的容错逻辑
- 覆盖服务端下发的配置值

**静态示例：**
```json
{ "status": "ok", "items": [] }
```

**动态示例（JS 函数）：**
```js
function modifyResponse(args) {
  const data = JSON.parse(args.body);
  data.items = [{ id: 1, name: "测试数据" }];
  return JSON.stringify(data);
}
```

---

### 6. 📋 修改请求头 / 响应头（Modify Headers）

添加、修改或删除请求头和响应头。

**适用场景：**
- 不改代码直接注入 `Authorization` Token
- 给响应加上 `Access-Control-Allow-Origin: *` 解决开发时的跨域问题
- 删掉某个影响调试的 Header

**示例：**
```
添加请求头：   Authorization = Bearer my-dev-token
添加响应头：   Access-Control-Allow-Origin = *
```

---

### 7. 📱 修改 User-Agent

覆盖浏览器发出的 UA 字符串——可选设备预设、浏览器预设，或完全自定义。

**适用场景：**
- 不打开 DevTools 模拟模式就能测移动端布局
- 模拟其他浏览器检验兼容性
- 测试按客户端类型返回不同内容的接口

**示例：**
```
选择预设：iPhone 15 → Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 ...) AppleWebKit/...
```

---

### 8. 🚫 取消请求（Cancel Request）

直接拦截请求，让它永远不会发出去。

**适用场景：**
- 调试时屏蔽掉噪音多的埋点或统计请求
- 屏蔽广告或第三方脚本，隔离性能问题
- 模拟某个接口的网络故障

**示例：**
```
匹配 URL 包含：  analytics.example.com
动作：           取消请求
```

---

### 9. ⏱ 请求延迟（Request Delay）

在请求发出前人为加入一段延迟（毫秒）。

**适用场景：**
- 模拟慢网络，测试 Loading 动画和骨架屏的表现
- 复现只在高延迟下才出现的竞态问题
- 压测超时和重试逻辑

**示例：**
```
匹配 URL 包含：  /api/search
延迟：           2000 毫秒
```

---

## 🔍 匹配与过滤

每条规则都可以配置多个精细条件，确保只在特定情况下生效。

| 选项 | 说明 |
|---|---|
| **匹配目标** | 匹配完整 `URL` 或只匹配 `HOST` |
| **匹配方式** | `contains`（包含）/ `equals`（等于）/ `regex`（正则）/ `wildcard`（通配符）|
| **页面域名** | 仅当请求来自指定页面时才生效 |
| **资源类型** | 限定 XHR、script、image、stylesheet 等 |
| **请求方法** | GET、POST、PUT、DELETE 等 |
| **请求头条件** | 根据某个请求头的值匹配（等于 / 不等于 / 包含）|

---

## 📦 导入与导出

- **导出**：将所有规则保存为 JSON 文件，方便备份或分享给队友
- **导入**：导入 JSON 文件，重复 ID 自动处理，不会冲突

---

## ⚠️ 注意事项

- **正则匹配**：保存前请确认正则表达式合法有效。
- **动态改写脚本**：函数签名必须完全一致：
  - 请求体改写：`function modifyRequestBody(args) { ... }`
  - 响应体改写：`function modifyResponse(args) { ... }`
- **规则优先级**：多条规则同时命中同一请求时，规则顺序和类型决定最终效果，可以拖拽规则调整顺序。
- **两套底层能力：**
  - `declarativeNetRequest` —— 浏览器原生 API，稳定高效（用于重定向、Header、取消请求、UA 等）
  - 注入脚本 —— 更灵活，用于请求体 / 响应体改写和延迟模拟

---

## 🧑‍💻 开发

```bash
# 安装依赖
npm install

# 监听模式（文件变动自动重建）
npm run dev

# 同时构建 Chrome 和 Firefox
npm run build

# 单独构建
npm run build:chrome
npm run build:firefox

# 检查内部引用
npm run check:references

# 打包 Firefox .xpi
npm run package:firefox
```

**构建产物：**
- `dist/chrome/`
- `dist/firefox/`
- `dist/requestman-firefox.xpi`（执行 `package:firefox` 后生成）
