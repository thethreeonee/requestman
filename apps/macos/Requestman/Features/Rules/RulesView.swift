import SwiftUI

struct RulesView: View {
    var body: some View {
        ContentUnavailableView(
            "规则功能准备中",
            systemImage: "slider.horizontal.3",
            description: Text("后续在这里配置请求修改、响应修改与 Mock。浏览器扩展中的规则继续独立使用。")
        )
    }
}
