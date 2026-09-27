import Foundation

struct URLRewriteProcessor: StepProcessor {
    func process(_ step: ModificationStep, draft: inout HTTPMessageDraft, context: ModificationExecutionContext) throws {
        let value = step.usesBodyFile ? step.value : try context.resolve(step.value, step: step)
        if step.effectiveURLRewriteTarget == .fullURL {
            guard let url = URL(string: value), ["http", "https"].contains(url.scheme ?? ""), url.host != nil, url.user == nil, url.fragment == nil else {
                throw WorkflowError.invalid("当前目标改写只支持完整的 http:// 或 https:// 地址")
            }
            draft.url = value
            return
        }

        try HTTPMessageValidation.validateEditedURL(draft.url)
        guard var target = URLComponents(string: draft.url) else { throw WorkflowError.invalid("当前请求 URL 无效") }
        switch step.effectiveURLRewriteTarget {
        case .fullURL: break
        case .host:
            guard !value.isEmpty,
                  !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
                  !value.contains(where: { "/?#@%\\".contains($0) }), !value.hasSuffix(":"),
                  let authority = URLComponents(string: "http://" + value),
                  let host = authority.host, !host.isEmpty,
                  authority.user == nil, authority.password == nil,
                  authority.path.isEmpty, authority.query == nil, authority.fragment == nil,
                  authority.port.map({ (1...65535).contains($0) }) ?? true else {
                throw WorkflowError.invalid("请输入主机名或 IP，可附加 1–65535 的端口；IPv6 地址需使用方括号")
            }
            target.percentEncodedHost = authority.percentEncodedHost
            if let port = authority.port { target.port = port }
        case .path:
            guard value.hasPrefix("/"), !value.contains("?"), !value.contains("#"),
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  value.range(of: "%(?![0-9A-Fa-f]{2})", options: .regularExpression) == nil,
                  let path = value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.union(CharacterSet(charactersIn: "%"))) else {
                throw WorkflowError.invalid("路径需以 / 开头；查询参数和片段请勿填入路径，字面 ? 和 # 请使用 %3F 和 %23")
            }
            target.percentEncodedPath = path
        }
        guard let rewritten = target.string else { throw WorkflowError.invalid("修改后的 URL 无效") }
        try HTTPMessageValidation.validateEditedURL(rewritten)
        draft.url = rewritten
    }
}
