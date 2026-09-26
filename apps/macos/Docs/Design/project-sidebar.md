# 项目侧栏

2026-09-26：用户选择方案 2，并要求整行浅灰 hover 背景及淡入淡出。初版静态稿见 [project-sidebar-hover-v1.png](project-sidebar-hover-v1.png)。随后按用户六项反馈修订：底部搜索与添加、统一行高、名称竖向对齐、双击展开、展开动画和纯图标网格。初版图保留作历史参考，当前行为以以下契约和源码为准。

## 布局与交互

- 保留项目 → 请求修改两层。项目有原生展开箭头和 SF Symbol，子项只显示名称。
- 树形内容整体增加 8 pt 左侧留白，箭头、图标与名称同步右移；数量和操作栏仍贴合原有右侧位置。
- 文件夹与规则统一为 30 pt，不用额外行高制造分组间距；两级名称左边缘位于同一条竖线，文件夹通过展开箭头和图标表达层级。图标固定 16 × 16 pt，与名称相隔 8 pt；箭头、图标与文字垂直居中。
- 恢复原来的底部操作行：加号在左、搜索在右，高度和垂直中心一致；两侧留白 12 pt、控件间隔 10 pt、底部留白 10 pt。移除新增的顶部标题行。以上尺寸为本产品设计值，不是 Apple HIG 强制数值。
- 数量独立靠右对齐，24 pt 操作栏始终预留；更多按钮在 hover、选中或菜单打开时显示，按钮出现不挤动文字。长名称居中省略，悬停显示全文。
- 单击行只选择，双击文件夹名称或行内空白展开/收起；规则双击不折叠父文件夹。原生箭头仍可单击展开，左右键管理展开，上下键移动选择。双击箭头不叠加文件夹行的双击处理。折叠项目不清除正在编辑的流程，会话内保留展开选择。搜索及新建后仍揭示新选中的流程。
- 项目更多菜单支持“添加请求修改”，新请求直接归属该项目。原有禁用、复制、重命名、图标、导出与删除入口保留。右键及键盘选中后可用的原生按钮提供替代入口。

## 图标选择

图标预览将 SF Symbol 等比缩放到最长边 16 pt，居中绘制在 16 × 16 pt 的模板图像中。使用紧凑画布，避免透明边距被原生菜单一起缩放后导致图标过小；格子的留白与点击范围由原生 palette 提供。保留模板图像，避免裸 SF Symbol 被菜单按较大字号重新配置。

“修改图标”子菜单使用原生 `NSMenu.presentationStyle = .palette`，按六列、八行展示 48 个 SF Symbols 候选，覆盖文件、网络、设备、开发工具和通用标记。仅显示图标，不显示名称；中文名称保留在 tooltip 和辅助功能标签中。当前图标保持选中状态，跨行选择会清除其他行的选中标记。macOS 27 显式设置 `preferredImageVisibility = .visible`，避免系统菜单隐藏图标。旧系统不存在的 symbol 自动过滤。

## 展开收起动画

双击使用 `NSTableView.doubleAction`，保留原生鼠标与手势处理。展开/收起同步调用一次原生方法，随后在事件事务结束后使用显式 `CABasicAnimation`：保留行从 presentation 位置移动到新位置，新子项以 8 pt 位移淡入，移除子项的可见行快照淡出。统一使用 180 ms 的 ease-in-ease-out 曲线。

箭头通过 Apple 公开的 `disclosureButtonIdentifier` / `makeView` 扩展点提供原生 `NSButton`，沿用系统按钮的 target/action，保留 disclosure 辅助功能角色与展开值。两种状态固定使用同一个 `chevron.right` SF Symbol，按钮为 20 × 20 pt，中心与行内容对齐。旋转在状态变更时同步建立，读取 presentation 当前角度，以 33 个居中旋转关键帧完成 90° 转动，避免更换图形及 transform 平移插值引起跳动。

快速反向操作立即更新原生展开状态，并以递增代次取消过时动画；延迟回调只处理视觉层，不再次增删或展开节点。快照仅来自可见行，结束后释放，重新载入、脱离窗口及启用减少动态效果时取消。初始化、筛选与新选中流程的状态恢复不增加动画；通知只记录展开状态。减少动态效果时直接显示终态。

连续双击的崩溃现场停在辅助功能查询触发的步骤卡片 `NSBox` 配置阶段。步骤列表复用未变更的步骤视图、保留 `NSBox` 自有 content view，并跳过相同选中外观的重复设置；切换规则前停止旧编辑器观察。隐藏窗口压力测试尚未复现原始崩溃，不能据此认定真实 App 崩溃已完成验收。

## 悬停动画

使用 AppKit `NSTableRowView` 的独立背景子层，动画不改变文字、图标、行尺寸或系统选中背景。仅未选中行显示低透明度语义灰色，深色模式随系统语义颜色适配。没有自定义玻璃、边框或阴影。

`CABasicAnimation(keyPath: "opacity")` 使用 ease-in-ease-out：移入 0.12 秒、移出 0.16 秒。先读取 presentation 的当前透明度，再禁用隐式动画、更新 model 终值，使用固定 animation key 替换旧动画，避免快速反转时跳回端点。不使用 `fillMode` 固定动画终态。

选择行时立即移除 hover；行从列表移除、窗口失焦或脱离窗口时也清理。移动鼠标、滚动、刷新布局时重新核对指针位置；菜单打开期间保留操作入口。启用“减少动态效果”时立即更新终值。

## 验证

`check-rules-ui.py` 使用真实 UI 源码和替身模型，在隐藏 `NSWindow` 内检查布局、菜单、新增/搜索、展开和选择。展开验证检查行位移、透明度及箭头旋转的真实动画对象、每个旋转关键帧的中心不变，以及按钮与图标的光学中心对齐；覆盖双击动作入口、原生箭头和左右键。压力场景包含 24 个子项、16 个步骤、100 次快速反向展开、40 次编辑器替换、离屏步骤复用及搜索中断清理。另有 hover 终值/时长/选中优先和图标菜单回归。`check-native-sources.py` 检查 AppKit 边界和工程引用。此类检查不代表完整 App 的鼠标手感或视觉验收；实际窗口仍需核对快速连续双击、浅色/深色、滚动、失焦与减少动态效果。

## 参考

- [Apple Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [Apple Outline views](https://developer.apple.com/design/human-interface-guidelines/outline-views)
- [Apple Outline View Button Keys](https://developer.apple.com/documentation/appkit/outline-view-button-keys)
- [Apple CABasicAnimation](https://developer.apple.com/documentation/quartzcore/cabasicanimation)

修订稿由内置 ImageGen 生成，输入为用户选中的方案 2。提示词要求保留分组留白、文件夹图标、纯文字子项和顶部搜索，增加未选中项目的整行浅灰背景、固定数量/操作栏，并标注 120/160 ms、快速反转、选中优先和减少动态效果行为。图中具体数值对齐、背景边界与缩进以源码约束为准。
