import Foundation

enum BodyReplacement {
    static func replace(_ value: String, step: ModificationStep, in draft: inout HTTPMessageDraft) throws {
        if step.usesBodyFile {
            guard let path = step.bodyFilePath, !path.isEmpty else { throw WorkflowError.invalid("请选择映射的本地文件") }
            let url = URL(fileURLWithPath: path)
            let bytes: Data
            do {
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw WorkflowError.invalid("请选择普通文件")
                }
                bytes = try Data(contentsOf: url)
            } catch {
                throw WorkflowError.invalid("无法读取 Body 文件“\(url.lastPathComponent)”：\(error.localizedDescription)")
            }
            draft.replacementBodyData = bytes; draft.replacementBody = nil
        } else if step.bodyEncoding == .base64 {
            guard let bytes = Data(base64Encoded: value) else { throw WorkflowError.invalid("Body 不是有效的 Base64 数据") }
            draft.replacementBodyData = bytes; draft.replacementBody = nil
        } else {
            draft.replacementBody = value; draft.replacementBodyData = nil
        }
    }

}
