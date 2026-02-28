# requestman

一个 Chrome Manifest V3 插件示例：在 DevTools 新增 `Redirect Rules` 面板，支持按规则组管理请求重定向。

## 技术栈

- 构建工具：Vite
- UI 框架：React + Ant Design
- 拖拽能力：@dnd-kit
- 网络重定向：Chrome `declarativeNetRequest`

## 功能

- 在开发者工具新增自定义 Tab（`Redirect Rules`）。
- 规则组 + 规则两级开关。
- 规则支持：
  - 匹配范围：整个 URL / 仅 Host
  - 匹配方式：包含 / 等于 / 正则 / 通配符
- 正则模式支持重定向目标里的 `$1`、`$2` 分组替换。
- 支持拖拽：
  - 规则组排序
  - 规则排序
  - 规则拖到其他组
- 删除规则或规则组需要二次确认。

## 开发

```bash
npm install
npm run build
```

构建产物会统一输出到 `dist` 目录：

- `dist/manifest.json`
- `dist/background.js`
- `dist/devtools/devtools.html`
- `dist/devtools/devtools.js`
- `dist/panel-bundle/*`

DevTools 面板会加载 `dist/panel-bundle/index.html`。

## 安装

1. 打开 `chrome://extensions/`
2. 开启「开发者模式」
3. 点击「加载已解压的扩展程序」
4. 选择构建后的目录 `/workspace/requestman/dist`

## 使用

1. 打开任意页面并启动 DevTools。
2. 切换到 `Redirect Rules` 面板。
3. 创建规则组与规则并启用。
4. 请求命中后由 `declarativeNetRequest` 动态规则重定向。

## 注意

- 插件使用 `declarativeNetRequest`，规则会同步到浏览器动态网络规则。
- 当规则组关闭时，组内规则不会生效；规则开关会禁用但保留原状态。
- 非正则规则会直接重定向到固定 URL；正则规则使用 `regexSubstitution` 支持 `$1` 等占位符。
