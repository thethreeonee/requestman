import AppKit
import RequestmanCore

/// Both entry points freeze the clicked request, independent of later selection and log updates.
@MainActor
enum RequestActionsMenu {
    static func append(to menu: NSMenu, record: CaptureRecord, replayUnavailable: String?,
                       cancelReplay: @escaping (UUID) -> Void = { _ in },
                       revealSource: ((UUID) -> Void)? = nil,
                       contentCopyItem: NSMenuItem? = nil,
                       replay: @escaping (CaptureRecord, Bool) -> Void) {
        let reason = RequestReplayDraft.unavailableReason(for: record) ?? replayUnavailable
        menu.addItem(item("重放", reason: reason) { replay(record, false) })
        menu.addItem(item("编辑后重放…", reason: reason) { replay(record, true) })
        if let id = record.replayID, record.connectionState.isActive {
            menu.addItem(item("取消此次重放") { cancelReplay(id) })
        }
        if let source = record.replaySourceID {
            menu.addItem(item("查看原请求", reason: revealSource == nil ? "原请求已不在日志中" : nil) { revealSource?(source) })
        }
        menu.addItem(.separator())
        let copy = NSMenuItem(title: "复制", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "复制"); submenu.autoenablesItems = false
        submenu.addItem(item("复制 URL", reason: record.urlWasTruncated ? "URL 记录已截断" : nil) { RequestClipboard.copy(record.url) })
        if let contentCopyItem { submenu.addItem(contentCopyItem) }
        for (title, version) in [("复制原始请求 cURL", RequestCURL.Version.original), ("复制修改后请求 cURL", .modified)] {
            submenu.addItem(item(title, reason: RequestCURL.unavailableReason(for: record, version: version)) {
                if let command = RequestCURL.command(for: record, version: version) { RequestClipboard.copy(command) }
            })
        }
        copy.submenu = submenu; menu.addItem(copy)
    }

    static func item(_ title: String, reason: String? = nil, action: @escaping () -> Void) -> NSMenuItem {
        let item = RequestActionMenuItem(title: title, action: action)
        item.isEnabled = reason == nil
        item.toolTip = reason
        return item
    }
}

@MainActor
private final class RequestActionMenuItem: NSMenuItem {
    private let perform: () -> Void
    init(title: String, action: @escaping () -> Void) {
        perform = action
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { if isEnabled { perform() } }
}
