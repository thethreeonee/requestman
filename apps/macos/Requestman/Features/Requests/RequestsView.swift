import SwiftUI

struct RequestsView: View {
    var body: some View {
        ContentUnavailableView(
            "尚未接入流量捕获",
            systemImage: "network",
            description: Text("接入捕获服务后，这里将显示所选应用的请求与响应。")
        )
    }
}
