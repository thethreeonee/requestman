import Foundation
import RequestmanCore

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case rules, requests
    var id: Self { self }
    var title: String {
        switch self { case .rules: "请求修改"; case .requests: "请求日志" }
    }
}

extension ModificationKind {
    var symbolName: String {
        switch self {
        case .setHeader, .removeHeader: "slider.horizontal.3"
        case .modifyJSON: "curlybraces"
        case .replaceBody: "doc.text"
        case .rewriteURL: "link"
        case .setQueryParameter: "slider.horizontal.3"
        case .replaceURLString: "arrow.triangle.2.circlepath"
        case .setMethod: "arrow.left.arrow.right"
        case .setStatus: "number.circle"
        case .mock: "doc.on.doc"
        case .redirect: "arrow.turn.up.right"
        case .script: "chevron.left.forwardslash.chevron.right"
        case .delay: "clock"
        }
    }
    var stepDescription: String {
        switch self {
        case .setHeader, .removeHeader: "按顺序添加、修改或删除 Header"
        case .modifyJSON: "按路径添加、修改或删除 JSON 字段"
        case .replaceBody: "用文本或本地文件替换 Body"
        case .rewriteURL: "改写目标地址、主机或路径"
        case .setQueryParameter: "按名称添加、修改或删除查询参数"
        case .replaceURLString: "区分大小写，替换 URL 中所有匹配"
        case .setMethod: "修改发送到服务器的请求方法"
        case .setStatus: "修改返回给客户端的响应状态码"
        case .mock: "直接返回预设内容，无需请求服务器"
        case .redirect: "返回重定向，由客户端访问目标地址"
        case .script: "执行脚本，失败时停止当前流程"
        case .delay: "等待指定毫秒数后继续执行"
        }
    }
}
