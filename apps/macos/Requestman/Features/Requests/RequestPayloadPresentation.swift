import Foundation
import CoreFoundation
import RequestmanCore

/// Constructed only for the selected record's visited panes, off the main actor.
struct RequestPayloadPresentation: Sendable {
    var nodes: [RequestDataNode] = []
    var source = ""
    var copyText = ""
    var summary = ""
    var footer = ""
    var notice: String?
    var emptyTitle: String?
    var emptyDescription: String?
    var isJSON = false
    var canCompare = false

    static func make(record: CaptureRecord, tab: RequestDetailTab, version: InspectionVersion) -> Self {
        if record.outcome == .tunnel {
            return Self(emptyTitle: "加密隧道", emptyDescription: "此连接未解密，无法查看内部请求与响应。")
        }
        if !tab.isBody { return headers(record: record, tab: tab, version: version) }
        return body(record: record, tab: tab, version: version)
    }

    private static func headers(record: CaptureRecord, tab: RequestDetailTab, version: InspectionVersion) -> Self {
        let original = tab.isRequest ? record.requestHeaders : record.receivedHeaders
        let final = tab.isRequest ? record.sentHeaders : record.responseHeaders
        let originalInfo = tab.isRequest ? record.requestHeadersInfo : record.receivedHeadersInfo
        let finalInfo = tab.isRequest ? record.sentHeadersInfo : record.responseHeadersInfo
        let originalExists = tab.isRequest || record.originalStatus != nil
        let finalExists = tab.isRequest
            ? record.sentBody.state != .unavailable && (record.sentBody.state != .notCollected || !final.isEmpty)
            : record.status != nil
        let chosenExists = version == .original ? originalExists : finalExists
        if !chosenExists {
            let reason: String
            if tab.isRequest { reason = record.sentBody.unavailableReason ?? "请求未发送到服务器。" }
            else { reason = version == .original ? "此响应由代理生成，没有服务器原始响应。" : "未收到响应头。" }
            return Self(emptyTitle: "无\(tab.title)", emptyDescription: reason)
        }
        let comparisonAvailable = originalExists && finalExists
        // An absent message is not the same as an empty list of headers.
        var leftInfo = originalInfo
        var rightInfo = finalInfo
        if !comparisonAvailable { leftInfo.isTruncated = true; rightInfo.isTruncated = true }
        let nodes = RequestInspectionData.headers(original: originalExists ? original : [], final: finalExists ? final : [],
                                                  originalInfo: leftInfo, finalInfo: rightInfo, version: version)
        let fields = version == .original ? original : final
        let changes = nodes.filter { $0.change != .unchanged }.count
        var notes: [String] = []
        if originalInfo.isTruncated || finalInfo.isTruncated { notes.append("部分 Header 超出记录上限；不完整字段不计算差异。") }
        if !originalInfo.redactedNames.isEmpty || !finalInfo.redactedNames.isEmpty { notes.append("凭据已隐藏，不参与值比较。") }
        if version == .difference && !comparisonAvailable { notes.append("没有可对照的原始消息，当前显示最终内容。") }
        return Self(nodes: nodes,
                    copyText: fields.map { "\($0.name): \($0.value)" }.joined(separator: "\r\n"),
                    summary: "\(nodes.count) 项", footer: "\(changes) 处可见变更",
                    notice: notes.isEmpty ? nil : notes.joined(separator: " "),
                    emptyTitle: nodes.isEmpty ? "无 Header" : nil, canCompare: comparisonAvailable)
    }

    private static func body(record: CaptureRecord, tab: RequestDetailTab, version: InspectionVersion) -> Self {
        let original = tab.isRequest ? record.requestBody : record.receivedBody
        let final = tab.isRequest ? record.sentBody : record.responseBody
        let selected = version == .original ? original : final
        let selectedContent = PreparedBody(snapshot: selected)
        var result = Self(source: selectedContent.text, copyText: selectedContent.text,
                          summary: "\(selected.contentType?.components(separatedBy: ";").first ?? "Body") · \(size(selected.observedByteCount))",
                          notice: selectedContent.notice, emptyTitle: selectedContent.emptyTitle,
                          emptyDescription: selectedContent.emptyDescription)
        let originalContent = version == .original ? selectedContent : PreparedBody(snapshot: original)
        let finalContent = version == .original ? PreparedBody(snapshot: final) : selectedContent
        let completeComparison = originalContent.completeData != nil && finalContent.completeData != nil
        result.canCompare = completeComparison
        // An explicitly cleared body still needs an original/final comparison.
        if version == .difference, completeComparison,
           originalContent.completeData != finalContent.completeData, selectedContent.completeData?.isEmpty == true {
            result.emptyTitle = nil
            result.emptyDescription = nil
            result.source = "原始\n\(originalContent.text)\n\n最终\n（无 Body）"
            result.footer = "原始与最终内容不同"
            return result
        }
        guard result.emptyTitle == nil else { return result }
        if version == .difference && !completeComparison {
            result.notice = [result.notice, "原始或最终内容不完整，无法计算差异；当前显示最终预览。"].compactMap { $0 }.joined(separator: " ")
        }
        if let data = selectedContent.completeData, !data.isEmpty {
            do {
                result.nodes = try RequestInspectionData.json(original: originalContent.completeData,
                                                              final: finalContent.completeData, version: version)
                result.isJSON = true
                if completeComparison {
                    let counterpart = version == .original ? finalContent.completeData : originalContent.completeData
                    let counterpartTree = try? RequestInspectionData.json(original: counterpart, final: nil, version: .original)
                    if counterpartTree?.isEmpty != false {
                        // Complete bytes can be compared as source even when one side
                        // is not representable as JSON. Do not offer an empty field diff.
                        if version == .difference {
                            result.nodes = []
                            result.isJSON = false
                            result.notice = [result.notice, "两侧内容无法以 JSON 树对照，当前显示原始与最终源码。"].compactMap { $0 }.joined(separator: " ")
                        } else { result.canCompare = false }
                    }
                }
            } catch {
                // Text/binary/invalid JSON remains inspectable in the source pane.
                if selected.contentType?.lowercased().contains("json") == true {
                    result.notice = [result.notice, "JSON 无法以树形展示：\(error.localizedDescription)"].compactMap { $0 }.joined(separator: " ")
                }
            }
        }
        if completeComparison {
            let equal = originalContent.completeData == finalContent.completeData
            result.footer = equal ? "内容未变化" : "原始与最终内容不同"
            if version == .difference && !equal {
                let oldText = originalContent.completeData?.isEmpty == true ? "（无 Body）" : originalContent.text
                let newText = finalContent.completeData?.isEmpty == true ? "（无 Body）" : finalContent.text
                result.source = "原始\n\(oldText)\n\n最终\n\(newText)"
            }
        } else { result.footer = selected.isComplete ? "\(size(selected.data.count)) 已记录" : "内容预览" }
        return result
    }

    private static func size(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    private struct PreparedBody {
        var text = ""
        var completeData: Data?
        var notice: String?
        var emptyTitle: String?
        var emptyDescription: String?

        init(snapshot: CaptureBodySnapshot) {
            switch snapshot.state {
            case .notCollected:
                emptyTitle = "未采集 Body"
                emptyDescription = "这条记录没有可用的内容快照。"
                return
            case .unavailable:
                emptyTitle = "无可用 Body"
                emptyDescription = snapshot.unavailableReason
                return
            case .complete, .incomplete: break
            }
            if snapshot.isComplete && snapshot.observedByteCount == 0 && !snapshot.isEncoded {
                completeData = Data()
                emptyTitle = "无 Body"
                emptyDescription = "此消息没有内容。"
                return
            }
            var data = snapshot.data
            var notes: [String] = []
            if snapshot.state == .incomplete { notes.append("传输未完成，以下内容可能不完整。") }
            if snapshot.isTruncated {
                notes.append("仅记录 \(size(data.count)) / \(size(snapshot.observedByteCount))；内容已截断。")
            }
            if snapshot.isComplete {
                do {
                    data = try RequestBodyDecoding.decode(snapshot)
                    completeData = data
                    if snapshot.isEncoded { notes.append("已解码 \(snapshot.contentEncoding ?? "")；原始传输大小 \(size(snapshot.observedByteCount))。") }
                } catch { notes.append(error.localizedDescription) }
            }
            if data.isEmpty {
                if completeData != nil {
                    emptyTitle = "无 Body"
                    emptyDescription = "此消息没有内容。"
                    notice = notes.isEmpty ? nil : notes.joined(separator: " ")
                } else {
                    emptyTitle = "没有可用的内容预览"
                    emptyDescription = notes.joined(separator: " ")
                }
                return
            }
            if !snapshot.isEncoded || completeData != nil {
                if let value = Self.text(data, contentType: snapshot.contentType) { text = value }
                else {
                    text = Self.hex(data)
                    notes.append("二进制内容，以十六进制显示。")
                }
            } else {
                text = Self.hex(data)
                notes.append("压缩内容无法完整解码，以已记录字节显示。")
            }
            notice = notes.isEmpty ? nil : notes.joined(separator: " ")
        }

        private static func text(_ data: Data, contentType: String?) -> String? {
            var encoding = String.Encoding.utf8
            if let charset = contentType?.components(separatedBy: ";").dropFirst().first(where: {
                $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("charset=")
            })?.components(separatedBy: "=").dropFirst().joined(separator: "=") {
                let name = charset.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
                let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
                if cfEncoding != kCFStringEncodingInvalidId { encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding)) }
            }
            guard let text = String(data: data, encoding: encoding),
                  !text.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 9 && $0.value != 10 && $0.value != 13 }) else { return nil }
            return text
        }

        private static func hex(_ data: Data) -> String {
            let bytes = Array(data)
            return stride(from: 0, to: bytes.count, by: 16).map { offset in
                let end = min(offset + 16, bytes.count)
                let values = bytes[offset..<end].map { String(format: "%02x", $0) }.joined(separator: " ")
                return String(format: "%08x  ", offset) + values
            }.joined(separator: "\n")
        }
    }
}
