import AppKit
import RequestmanCore
import RequestmanEditor

@main @MainActor
struct RequestReplayEditorChecks {
    static func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? [] + view.subviews.flatMap { views(type, in: $0) }
    }
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        checkHistory()
        for binary in [false, true] {
            let bytes = binary ? Data([0, 255, 42]) : Data("{\"name\":\"before\"}".utf8)
            var initial = RequestReplayDraft(method: "POST", url: "https://example.test/original", headers: [HTTPField("X-Test", "one"), HTTPField("X-Test", "two")], body: bytes)
            initial.sourceRecordID = UUID()
            var submitted: RequestReplayDraft?
            let editor = RequestReplayEditor(draft: initial) { submitted = $0; throw WorkflowError.invalid("fixture failure") }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentViewController = editor
            let fields = views(NSTextField.self, in: editor.view)
            let url = fields.first { $0.accessibilityLabel() == "请求 URL" }!
            let method = fields.first { $0.accessibilityLabel() == "请求方法" }!
            let editors = views(CodeEditorView.self, in: editor.view)
            precondition(editors.count == 2)
            let submit = views(NSButton.self, in: editor.view).first { $0.title == "重放" }!
            precondition(submit.isEnabled)
            url.stringValue = "invalid"
            editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: url))
            precondition(!submit.isEnabled)
            url.stringValue = "https://example.test/edited?q=2"; method.stringValue = "PUT"
            editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: url))
            precondition(submit.isEnabled)
            if !binary { editors[1].string = "edited body" }
            submit.performClick(nil)
            let deadline = Date().addingTimeInterval(2)
            while submitted == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            precondition(submitted?.url == url.stringValue && submitted?.method == "PUT")
            precondition(submitted?.headers == initial.headers)
            precondition(submitted?.sourceRecordID == initial.sourceRecordID)
            precondition(submitted?.body == (binary ? bytes : Data("edited body".utf8)))
            precondition(submit.isEnabled, "A failed send must allow retry and retain input")
            precondition(fields.contains { $0.stringValue == "fixture failure" })
            window.close()
        }
        print("Replay editor component checks passed: input validation, edited request submission, duplicate headers, binary preservation and failure retry, replay result focus, filter preservation and completion feedback. No App or network request was run.")
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
    }

}
