# requestman

`requestman` 是一个面向前端/接口调试场景的浏览器扩展（Chrome / Firefox），在 DevTools 中提供统一的请求规则面板，可对网络请求进行重定向、改写、拦截和延迟等操作。

> 当前版本并不只是“请求重定向”插件，而是一个多规则类型的请求调试工具。

## 技术栈

- 构建工具：Vite
- UI：React + Ant Design
- 编辑器：CodeMirror（用于动态脚本编辑）
- 能力实现：
  - `declarativeNetRequest`（重定向 / Header / UA / 取消请求等）
  - 注入脚本（请求体/响应体改写、请求延迟）

## 核心能力

### 1) 规则组织与启停

- DevTools 新增 `Redirect Rules` 面板
- 全局总开关
- 规则组（分组）管理：创建、重命名、复制、删除、折叠
- 规则管理：创建、编辑、启停、复制、删除
- 拖拽排序（组内排序、跨组移动）

### 2) 支持的规则类型

当前支持以下 9 类规则：

1. `redirect_request`：请求重定向（URL/Host 匹配后跳转到目标地址或扩展内文件）
2. `rewrite_string`：字符串重写（按匹配条件替换 URL 片段）
3. `query_params`：Query 参数增删改
4. `modify_request_body`：改写请求体（静态文本或动态 JS 函数）
5. `modify_response_body`：改写响应体（静态文本或动态 JS 函数）
6. `modify_headers`：修改请求/响应 Headers（add/update/delete）
7. `user_agent`：修改 User-Agent（设备预设、浏览器预设、自定义）
8. `cancel_request`：取消请求
9. `request_delay`：请求延迟（毫秒）

### 3) 匹配与过滤

每条规则可配置多个条件（conditions），支持：

- 匹配目标：`URL` / `HOST`
- 匹配方式：`contains` / `equals` / `regex` / `wildcard`
- 过滤器：
  - 页面域名（initiator）
  - 资源类型（XHR、script、image 等）
  - 请求方法（GET/POST/PUT...）
  - 请求头键值条件（equals/not_equals/contains）

### 4) 调试与配置迁移

- 支持规则导出为 JSON
- 支持规则导入（自动处理冲突 ID）
- 详情页离开前未保存变更提醒
- 删除规则/规则组二次确认

## 开发

安装依赖：

```bash
npm install
```

开发模式（监听构建）：

```bash
npm run dev
```

完整构建（同时输出 Chrome / Firefox）：

```bash
npm run build
```

单独构建：

```bash
npm run build:chrome
npm run build:firefox
```

引用检查：

```bash
npm run check:references
```

打包 Firefox xpi：

```bash
npm run package:firefox
```

构建产物：

- `dist/chrome/*`
- `dist/firefox/*`
- `dist/requestman-firefox.xpi`（执行 `npm run package:firefox` 后生成）

## 安装

### Chrome

1. 打开 `chrome://extensions/`
2. 开启开发者模式
3. 点击“加载已解压的扩展程序”
4. 选择 `dist/chrome`

### Firefox

1. 打开 `about:debugging#/runtime/this-firefox`
2. 点击“加载临时附加组件”
3. 选择 `dist/firefox/manifest.json`
   - 或直接安装 `dist/requestman-firefox.xpi`

## 使用流程

1. 打开任意页面并启动 DevTools
2. 切换到 `Redirect Rules` 面板
3. 创建规则组与规则，填写匹配条件和动作
4. 启用对应规则（并确认总开关、分组开关开启）
5. 刷新或重发请求验证效果

## 注意事项

- 使用正则匹配时，请确保表达式合法。
- 请求体/响应体动态改写依赖你提供的 JS 函数签名：
  - 请求体：`modifyRequestBody(args)`
  - 响应体：`modifyResponse(args)`
- 多条规则同时命中时，实际行为受规则顺序、优先级及浏览器能力限制影响。
- `declarativeNetRequest` 与注入脚本是两套能力：
  - 前者更稳定、浏览器原生支持
  - 后者适合更灵活的 Body 改写与延迟模拟
