import AppKit
import RequestmanCore

enum RecordColumn: String, CaseIterable {
    case time, status, request, header, rules, device, duration
    var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }
    var title: String {
        switch self {
        case .time: "时间"
        case .status: "状态码"
        case .request: "请求"
        case .header: "Header"
        case .rules: "命中的规则"
        case .device: "设备来源"
        case .duration: "耗时"
        }
    }
    static var standard: [Self] { allCases.filter { $0 != .header } }
}

struct RequestLogDisplayOptions: Equatable {
    static let defaultsKey = "requestLog.displayOptions.v1"
    var columns = Set(RecordColumn.standard)
    var headerEnabled = false
    var headerName = ""
    var headerSource = HeaderSource.originalRequest
    var trimmedHeaderName: String { headerName.trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasValidHeaderName: Bool {
        let name = trimmedHeaderName
        let allowed = "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        return !name.isEmpty && name.utf8.allSatisfy { allowed.utf8.contains($0) }
    }

    enum HeaderSource: String, CaseIterable {
        case originalRequest, sentRequest, originalResponse, returnedResponse
        var title: String {
            switch self {
            case .originalRequest: "原始请求"
            case .sentRequest: "发出的请求"
            case .originalResponse: "原始响应"
            case .returnedResponse: "返回的响应"
            }
        }
        func fields(in record: CaptureRecord) -> [HTTPField] {
            switch self {
            case .originalRequest: record.requestHeaders
            case .sentRequest: record.sentHeaders
            case .originalResponse: record.receivedHeaders
            case .returnedResponse: record.responseHeaders
            }
        }
    }

    func isVisible(_ column: RecordColumn, allowLAN: Bool) -> Bool {
        if column == .header { return headerEnabled && hasValidHeaderName }
        return columns.contains(column) && (column != .device || allowLAN)
    }

    func headerValue(in record: CaptureRecord) -> String {
        guard headerEnabled, hasValidHeaderName else { return "—" }
        let values = headerSource.fields(in: record)
            .filter { $0.name.caseInsensitiveCompare(trimmedHeaderName) == .orderedSame }.map(\.value)
        return values.isEmpty ? "—" : values.joined(separator: "\n")
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let saved = defaults.dictionary(forKey: defaultsKey) else { return Self() }
        var options = Self()
        if let names = saved["columns"] as? [String] {
            options.columns = Set(names.compactMap(RecordColumn.init(rawValue:))).intersection(RecordColumn.standard)
            // Always retain a standard column that is available with LAN disabled.
            if options.columns.subtracting([.device]).isEmpty { options.columns.insert(.request) }
        }
        options.headerEnabled = saved["headerEnabled"] as? Bool ?? false
        options.headerName = saved["headerName"] as? String ?? ""
        options.headerSource = (saved["headerSource"] as? String).flatMap(HeaderSource.init(rawValue:)) ?? .originalRequest
        return options
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(["columns": columns.map(\.rawValue).sorted(), "headerEnabled": headerEnabled,
                      "headerName": headerName, "headerSource": headerSource.rawValue], forKey: Self.defaultsKey)
    }
}

@MainActor
final class RequestLogDisplayOptionsController: NSViewController {
    private var options: RequestLogDisplayOptions
    private var allowLAN: Bool
    private let onChange: (RequestLogDisplayOptions) -> Void
    private var checkboxes: [RecordColumn: NSButton] = [:]
    private let headerToggle = NSButton(checkboxWithTitle: "显示 Header 列", target: nil, action: nil)
    private let source = NSPopUpButton(frame: .zero, pullsDown: false)
    private lazy var name = HeaderNameField(name: options.headerName) { [weak self] value in
        guard let self else { return }
        options.headerName = value
        changed()
    }
    private let validation = NativeUI.label("", size: 11, secondary: true)

    init(options: RequestLogDisplayOptions, allowLAN: Bool, onChange: @escaping (RequestLogDisplayOptions) -> Void) {
        self.options = options; self.allowLAN = allowLAN; self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        var rows: [NSView] = [NativeUI.label("显示选项", size: 14, weight: .semibold)]
        for column in RecordColumn.standard {
            let button = NSButton(checkboxWithTitle: column == .request ? "请求（URL）" : column.title,
                                  target: self, action: #selector(toggleColumn(_:)))
            button.identifier = column.identifier
            checkboxes[column] = button
            rows.append(button)
        }
        headerToggle.target = self; headerToggle.action = #selector(toggleHeader)
        source.addItems(withTitles: RequestLogDisplayOptions.HeaderSource.allCases.map(\.title))
        source.target = self; source.action = #selector(changeSource)
        source.setAccessibilityLabel("Header 来源")
        rows += [NativeUI.separator(), headerToggle, NativeUI.label("来源", size: 12, secondary: true),
                 source, NativeUI.label("Header 名称", size: 12, secondary: true), name, validation]
        let stack = NativeUI.stack(rows, spacing: 8)
        NativeUI.pin(stack, to: view, insets: NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16))
        name.widthAnchor.constraint(equalToConstant: 280).isActive = true
        source.widthAnchor.constraint(equalTo: name.widthAnchor).isActive = true
        validation.widthAnchor.constraint(equalTo: name.widthAnchor).isActive = true
        update(options: options, allowLAN: allowLAN)
        preferredContentSize = view.fittingSize
    }

    func update(options: RequestLogDisplayOptions, allowLAN: Bool) {
        self.options = options; self.allowLAN = allowLAN
        guard isViewLoaded else { return }
        let available = options.columns.subtracting([.device])
        for (column, button) in checkboxes {
            button.state = options.columns.contains(column) ? .on : .off
            button.isEnabled = column == .device ? allowLAN : !(available.count == 1 && available.contains(column))
            button.toolTip = column == .device && !allowLAN ? "开启允许局域网设备连接后可显示" : nil
        }
        headerToggle.state = options.headerEnabled ? .on : .off
        source.selectItem(at: RequestLogDisplayOptions.HeaderSource.allCases.firstIndex(of: options.headerSource) ?? 0)
        source.isEnabled = options.headerEnabled
        name.isEnabled = options.headerEnabled
        if name.stringValue != options.headerName { name.stringValue = options.headerName }
        validation.stringValue = options.headerEnabled && !options.trimmedHeaderName.isEmpty && !options.hasValidHeaderName
            ? "请输入有效的 Header 名称" : "Header 列显示在请求（URL）之后"
    }

    private func changed() {
        update(options: options, allowLAN: allowLAN)
        onChange(options)
    }
    @objc private func toggleColumn(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let column = RecordColumn(rawValue: value) else { return }
        if sender.state == .on { options.columns.insert(column) } else { options.columns.remove(column) }
        changed()
    }
    @objc private func toggleHeader() { options.headerEnabled = headerToggle.state == .on; changed() }
    @objc private func changeSource() {
        guard RequestLogDisplayOptions.HeaderSource.allCases.indices.contains(source.indexOfSelectedItem) else { return }
        options.headerSource = RequestLogDisplayOptions.HeaderSource.allCases[source.indexOfSelectedItem]
        changed()
    }
}
