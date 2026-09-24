# TransparentProxy 系统扩展边界

这里保留后续 `NETransparentProxyProvider` 系统扩展的代码位置。当前没有扩展 target、provider 占位实现或生效的 entitlements，宿主 App 也不会安装系统扩展。

真实实现接入时一起补齐：

- 独立 System Extension target、入口、Info.plist 中的 provider 注册。
- 同一签名团队、独立 Bundle ID、正确的 Network Extension entitlement，以及宿主的安装权限和嵌入阶段。
- 通过 `OSSystemExtensionRequest` 管理安装/卸载，使用透明代理配置管理器控制启停，并处理用户授权和重启要求。
- 带版本的 IPC、调用方身份校验、目标应用签名及辅助进程解析。
- 非目标流量直接放行；目标流量只在本地代理引擎确实就绪时接管。
- 自身/Surge 流量排除、引擎崩溃恢复、停用和升级处理。

扩展负责流量接管；HTTP、TLS 与规则处理交给代理核心。详细约束见 [架构文档](../../Docs/Architecture.md)。
