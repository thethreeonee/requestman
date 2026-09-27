import AppKit
import RequestmanCore
import RequestmanEditor

// Supply native key-window drawing for the isolated, non-visible component.
@MainActor private final class ReplayCheckWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@main @MainActor
struct RequestReplayEditorChecks {
    static func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        checkHistory()
        for binary in [false, true] { checkEditor(binary: binary) }
        captureDesign()
        print("Replay editor component checks passed: native header table, live validation, method selection, colored shared body editor, duplicate/whitespace preservation, Base64, submission locking and failure retry. Hidden components only; no App or network request was run.")
    }

    private static func window(for editor: RequestReplayEditor) -> NSWindow {
        let window = ReplayCheckWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 780), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = editor
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private static func settle(_ seconds: TimeInterval = 0.2) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private static func edit(_ field: NSTextField, to value: String) {
        field.stringValue = value
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    private static func clickSegment(_ segment: Int, in control: NSSegmentedControl) {
        // Momentary controls expose the clicked segment only during real tracking.
        // Hold selection while exercising the target/action in this hidden fixture.
        let tracking = control.trackingMode
        control.trackingMode = .selectOne
        control.selectedSegment = segment
        NSApp.sendAction(control.action!, to: control.target, from: control)
        control.trackingMode = tracking
    }

    private static func checkEditor(binary: Bool) {
        let bytes = binary ? Data([0, 255, 42]) : Data("{\"name\":\"before\",\"count\":2}".utf8)
        var initial = RequestReplayDraft(method: binary ? "PROPFIND" : "POST", url: "https://example.test/original", headers: [HTTPField("X-Test", "one"), HTTPField("X-Test", "  two \t")], body: bytes)
        initial.sourceRecordID = UUID()
        var submitted: RequestReplayDraft?
        let editor = RequestReplayEditor(draft: initial) { submitted = $0; throw WorkflowError.invalid("fixture failure") }
        let window = window(for: editor)
        let fields = views(NSTextField.self, in: editor.view)
        let url = fields.first { $0.accessibilityLabel() == "请求 URL" }!
        let method = views(NSPopUpButton.self, in: editor.view).first!
        precondition(views(NSComboBox.self, in: editor.view).isEmpty)
        precondition(method.titleOfSelectedItem == initial.method)
        let editors = views(CodeEditorView.self, in: editor.view)
        precondition(editors.count == 1, "Body must reuse the shared code editor")
        let body = editors[0]
        precondition(body.language == (binary ? .plaintext : .json))
        let table = views(NSTableView.self, in: editor.view).first!
        let controls = views(NSSegmentedControl.self, in: editor.view).first!
        let submit = views(NSButton.self, in: editor.view).first { $0.title == "发送" }!
        precondition(submit.isEnabled && table.numberOfRows == 2)
        precondition(url.frame.width > 500, "URL must fill the remaining address row")
        edit(url, to: "invalid"); precondition(!submit.isEnabled)
        edit(url, to: "https://example.test/edited?q=2")
        method.selectItem(withTitle: "PUT")
        NSApp.sendAction(method.action!, to: method.target, from: method)
        precondition(method.titleOfSelectedItem == "PUT" && submit.isEnabled)

        clickSegment(0, in: controls)
        precondition(table.numberOfRows == 3 && !submit.isEnabled, "New blank header requires a valid name: rows=\(table.numberOfRows), enabled=\(submit.isEnabled), selected=\(controls.selectedSegment)")
        let added = (table.view(atColumn: 0, row: 2, makeIfNecessary: true) as! NSTableCellView).textField!
        edit(added, to: "Host"); precondition(!submit.isEnabled, "Managed fields cannot be overridden")
        edit(added, to: "X-Added"); precondition(submit.isEnabled)
        clickSegment(1, in: controls)
        precondition(table.numberOfRows == 2 && submit.isEnabled)

        settle(0.35)
        if !binary {
            var colors = Set<String>()
            let storage = body.textView.textStorage!
            storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                if let color = value as? NSColor { colors.insert(color.description) }
            }
            precondition(colors.count > 1, "Shared editor must actually apply syntax colors")
            body.replaceText(with: "edited body")
        } else {
            body.replaceText(with: "not base64!"); precondition(!submit.isEnabled)
            body.replaceText(with: bytes.base64EncodedString()); precondition(submit.isEnabled)
        }
        // Commit an active native field-editor change when the default action is invoked.
        let value = (table.view(atColumn: 1, row: 0, makeIfNecessary: true) as! NSTableCellView).textField!
        window.makeFirstResponder(value)
        if let fieldEditor = value.currentEditor() {
            fieldEditor.string = "changed"
            NotificationCenter.default.post(name: NSText.didChangeNotification, object: fieldEditor)
        } else { preconditionFailure("Expected native table field editor") }
        submit.performClick(nil)
        precondition(!submit.isEnabled && !method.isEnabled && !url.isEnabled && !controls.isEnabled && !body.textView.isEditable)
        let deadline = Date().addingTimeInterval(2)
        while submitted == nil && Date() < deadline { settle(0.01) }
        precondition(submitted?.url == url.stringValue && submitted?.method == "PUT")
        precondition(submitted?.headers == [HTTPField("X-Test", "changed"), initial.headers[1]], "Preserve duplicate order and untouched whitespace")
        precondition(submitted?.sourceRecordID == initial.sourceRecordID)
        precondition(submitted?.body == (binary ? bytes : Data("edited body".utf8)))
        precondition(submit.isEnabled && body.textView.isEditable && controls.isEnabled, "Failed send must unlock and retain input")
        precondition(fields.contains { $0.stringValue == "fixture failure" })
        precondition(initial.headers[0].value == "one", "Edits must not mutate the original request")
        window.close()
    }

    private static func captureDesign() {
        guard let directory = ProcessInfo.processInfo.environment["REQUESTMAN_REPLAY_SNAPSHOT_DIR"] else { return }
        let json = """
        {
          "customer_id": "cus_1024",
          "items": [
            {
              "product_id": "prod_128",
              "quantity": 2
            }
          ],
          "currency": "CNY"
        }
        """
        let draft = RequestReplayDraft(method: "POST", url: "https://api.example.com/v1/orders", headers: [HTTPField("Content-Type", "application/json"), HTTPField("Accept", "application/json"), HTTPField("X-Environment", "development"), HTTPField("X-Debug", "true")], body: Data(json.utf8))
        try! FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let editor = RequestReplayEditor(draft: draft) { _ in }
            let window = window(for: editor)
            window.appearance = NSAppearance(named: appearance)
            window.makeFirstResponder(views(NSTextField.self, in: editor.view).first { $0.accessibilityLabel() == "请求 URL" })
            editor.view.wantsLayer = true
            window.appearance!.performAsCurrentDrawingAppearance {
                editor.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            settle(0.4)
            let view = editor.view
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent("request-replay-\(name).png"))
            window.close()
        }
    }
    private static func checkHistory() {
        let history = ExecutionHistoryModel()
        var source = CaptureRecord(method: "GET", url: "https://example.test/source")
        source.requestBody = CaptureBodyCollector().snapshot(isComplete: true)
        history.append([source], dropped: 0)
        history.filter.search = "never-matches"
        history.paused = true
        let draft = try! RequestReplayDraft(record: source)
        history.beginReplay(draft)
        precondition(history.selectedID == draft.id && history.filtered.map(\.id) == [draft.id])
        precondition(history.latestReplay?.replaySummary == "重放进行中")
        var completed = history.latestReplay!
        completed.connectionState = .closed; completed.status = 201
        history.append([completed], dropped: 0)
        precondition(history.latestReplay?.replaySummary == "重放已完成 · HTTP 201")
        history.reveal(source.id)
        precondition(history.selectedID == source.id && history.filtered.map(\.id) == [source.id])
        history.filter.search = "changed-filter"
        precondition(history.filtered.isEmpty, "Changing the filter ends the temporary reveal")
        history.append((0..<520).map { CaptureRecord(method: "GET", url: "http://noise.test/\($0)") }, dropped: 0)
        precondition(history.records.count == 500 && history.latestReplay?.id == completed.id)
        history.clear()
        precondition(history.latestReplay == nil && history.selectedID == nil)
        history.filter.search = "source"
        history.append([source], dropped: 0); history.selectedID = source.id
        let fileRecords = (0..<510).map { CaptureRecord(method: "GET", url: "https://saved.test/\($0)") }
        history.openLog(fileRecords, name: "saved.requestmanlog.json")
        precondition(history.isViewingFile && history.records.count == 510 && history.filter.search.isEmpty)
        precondition(history.selectedID == fileRecords.first?.id)
        let arriving = CaptureRecord(method: "GET", url: "https://live.test/new")
        history.append([arriving], dropped: 3)
        precondition(history.records.map(\.id) == fileRecords.map(\.id), "Live traffic must not mutate an opened log")
        history.filter.search = "never-matches"
        history.reveal(fileRecords[0].id)
        precondition(history.filtered.count == 1 && history.recordsForSaving.isEmpty, "Export must obey the filter, not a reveal exception")
        history.returnToLive()
        precondition(history.records.map(\.id) == [arriving.id, source.id])
        precondition(history.filter.search == "source" && history.selectedID == source.id && history.dropped == 3)
        history.openLog(fileRecords, name: "saved.requestmanlog.json")
        history.beginReplay(try! RequestReplayDraft(record: source))
        precondition(!history.isViewingFile && history.latestReplay != nil)
        history.openLog(fileRecords, name: "saved.requestmanlog.json")
        history.clear()
        precondition(!history.isViewingFile && history.records.isEmpty)
    }

}
