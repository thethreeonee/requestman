# requestman

一个支持 Chrome / Firefox 的 Manifest V3 插件示例：在 DevTools 新增 `Redirect Rules` 面板，支持按规则组管理请求重定向。

## 技术栈

- 构建工具：Vite
- UI 框架：React + Ant Design
- 网络重定向：`declarativeNetRequest`

## 功能

- 在开发者工具新增自定义 Tab（`Redirect Rules`）。
- 规则组 + 规则两级开关。
- 规则支持：
  - 匹配范围：整个 URL / 仅 Host
  - 匹配方式：包含 / 等于 / 正则 / 通配符
- 正则模式支持重定向目标里的 `$1`、`$2` 分组替换。
- 删除规则或规则组需要二次确认。

## 开发

```bash
npm install
npm run build
```

构建时会同时输出 Chrome 和 Firefox 产物：

- `dist/chrome/*`
- `dist/firefox/*`

单独构建：

```bash
npm run build:chrome
npm run build:firefox
```

打包 Firefox xpi：

```bash
npm run package:firefox
```

打包结果：

- `dist/requestman-firefox.xpi`

## 安装

### Chrome

1. 打开 `chrome://extensions/`
2. 开启「开发者模式」
3. 点击「加载已解压的扩展程序」
4. 选择构建目录 `/workspace/requestman/dist/chrome`

### Firefox

1. 打开 `about:debugging#/runtime/this-firefox`
2. 点击「加载临时附加组件」
3. 选择 `/workspace/requestman/dist/firefox/manifest.json` 或直接安装 `dist/requestman-firefox.xpi`

## 使用

1. 打开任意页面并启动 DevTools。
2. 切换到 `Redirect Rules` 面板。
3. 创建规则组与规则并启用。
4. 请求命中后由 `declarativeNetRequest` 动态规则重定向。

## 注意

- 插件使用 `declarativeNetRequest`，规则会同步到浏览器动态网络规则。
- 当规则组关闭时，组内规则不会生效；规则开关会禁用但保留原状态。
- 非正则规则会直接重定向到固定 URL；正则规则使用 `regexSubstitution` 支持 `$1` 等占位符。
