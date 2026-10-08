import AppKit
import RequestmanCore

/// Edits appearance on the selected content instance; controls stay alive during text editing.
@MainActor
final class RequestLogContentAppearanceEditor: NSStackView, NSTextFieldDelegate {
    var onChange: (RequestLogContentAppearance) -> Void = { _ in }
    var onValidationChange: () -> Void = { }
    private var draftAppearance = RequestLogContentAppearance()
    private var thresholdField: NSTextField?
    private var thresholdRow: NSStackView?
    private var backgroundRow: NSStackView?
    private var backgroundSourceRow: NSStackView?
    private var backgroundTransparencyRow: NSStackView?
    private var backgroundTransparencyValue: NSTextField?
    private var backgroundColorWell: NSColorWell?
    private var borderRows: [NSStackView] = []
    private var borderColorRow: NSStackView?
    private var borderColorWell: NSColorWell?
    private var borderWidthField: NSTextField?
    private var borderWidthStepper: NSStepper?
    private var isDevice = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .vertical; alignment = .leading; spacing = 12
        detachesHiddenViews = true
    }
    required init?(coder: NSCoder) { nil }

    var validationError: String? {
        guard !isHidden else { return nil }
        if draftAppearance.presentation.isOutline, borderWidthField != nil, parsedBorderWidth == nil {
            return "边框粗细须为 0.5–8 pt"
        }
        if draftAppearance.highlightsSlowRequests, let thresholdField {
            guard let value = Int(thresholdField.stringValue), (1...3_600_000).contains(value) else {
                return "慢请求阈值须为 1–3600000 毫秒"
            }
        }
        return nil
    }

    func configure(content: RequestLogLayoutContent?) {
        backgroundColorWell?.deactivate()
        borderColorWell?.deactivate()
        for child in arrangedSubviews { removeArrangedSubview(child); child.removeFromSuperview() }
        thresholdField = nil; thresholdRow = nil
        backgroundRow = nil; backgroundColorWell = nil
        backgroundSourceRow = nil; backgroundTransparencyRow = nil
        backgroundTransparencyValue = nil
        borderRows = []; borderColorRow = nil; borderColorWell = nil
        borderWidthField = nil; borderWidthStepper = nil
        isHidden = content == nil
        guard let content else { return }
        draftAppearance = content.appearance
        isDevice = content.field == .device
        addFullWidth(NativeUI.separator())
        addArrangedSubview(NativeUI.label("外观", size: 14, weight: .semibold))
        if content.field != .device {
            menu("呈现", values: RequestLogContentPresentation.selectableCases,
                 selected: draftAppearance.presentation.effectivePresentation,
                 title: \.title) { $0.presentation = $1 }
        }
        makeBackgroundRow()
        makeBorderRows()
        menu("字体", values: RequestLogFont.allCases, selected: draftAppearance.font, title: \.title) { $0.font = $1 }
        menu("字重", values: RequestLogFontWeight.allCases, selected: draftAppearance.weight, title: \.title) { $0.weight = $1 }
        menu("省略", values: RequestLogTruncation.allCases, selected: draftAppearance.truncation, title: \.title) { $0.truncation = $1 }
        switch content.field {
        case .method:
            toggle("方法着色", selected: draftAppearance.usesSemanticColors) { $0.usesSemanticColors = $1 }
        case .status:
            toggle("状态着色", selected: draftAppearance.usesSemanticColors) { $0.usesSemanticColors = $1 }
            toggle("状态说明", selected: draftAppearance.showsStatusDescription) { $0.showsStatusDescription = $1 }
            toggle("异常强调", selected: draftAppearance.emphasizesErrors) { $0.emphasizesErrors = $1 }
        case .url:
            toggle("主机强调", selected: draftAppearance.emphasizesHost) { $0.emphasizesHost = $1 }
        case .time:
            menu("时间精度", values: RequestLogTimePrecision.allCases, selected: draftAppearance.timePrecision,
                 title: \.title) { $0.timePrecision = $1 }
        case .duration:
            menu("耗时单位", values: RequestLogDurationUnit.allCases, selected: draftAppearance.durationUnit,
                 title: \.title) { $0.durationUnit = $1 }
            menu("小数精度", values: RequestLogDecimalPrecision.allCases, selected: draftAppearance.durationPrecision,
                 title: \.title) { $0.durationPrecision = $1 }
            toggle("慢请求着色", selected: draftAppearance.highlightsSlowRequests) { $0.highlightsSlowRequests = $1 }
            makeThresholdRow()
        case .rules:
            menu("分隔符", values: RequestLogRuleSeparator.allCases, selected: draftAppearance.ruleSeparator,
                 title: \.title) { $0.ruleSeparator = $1 }
        case .header, .queryParameter:
            menu("重复值", values: RequestLogRepeatedValues.allCases, selected: draftAppearance.repeatedValues,
                 title: \.title) { $0.repeatedValues = $1 }
            toggle("数量提示", selected: draftAppearance.showsValueCount) { $0.showsValueCount = $1 }
        default: break
        }
        updateThresholdVisibility()
        updateBackgroundVisibility()
        updateBorderVisibility()
    }

    private func makeBackgroundRow() {
        backgroundSourceRow = menu("背景颜色", values: RequestLogBackgroundColorSource.allCases,
                                   selected: draftAppearance.backgroundColorSource, title: \.title) { $0.backgroundColorSource = $1 }
        let well = NSColorWell(frame: .zero)
        well.color = draftAppearance.backgroundColor?.appKitColor ?? .controlColor
        well.target = self; well.action = #selector(changeBackgroundColor(_:))
        well.setAccessibilityLabel("内容背景色")
        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetBackgroundColor(_:)))
        let controls = NativeUI.stack([well, reset], vertical: false, spacing: 8)
        well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        well.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let background = row("背景色", controls)
        backgroundColorWell = well; backgroundRow = background
        addFullWidth(background)

        let slider = NSSlider(frame: .zero)
        slider.minValue = 0; slider.maxValue = 100
        slider.doubleValue = (1 - draftAppearance.effectiveBackgroundOpacity) * 100
        slider.isContinuous = true
        slider.target = self; slider.action = #selector(changeBackgroundTransparency(_:))
        slider.setAccessibilityLabel("背景透明度，百分比，0 为不透明，100 为完全透明")
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let value = NativeUI.label("", secondary: true)
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 64).isActive = true
        backgroundTransparencyValue = value
        updateBackgroundTransparencyValue(slider.doubleValue)
        let transparency = row("透明度", NativeUI.stack([slider, value], vertical: false, spacing: 8))
        transparency.toolTip = "0% 为不透明，100% 为完全透明；仅调整跟随文本的背景"
        backgroundTransparencyRow = transparency
        addFullWidth(transparency)
    }

    private var showsBackgroundControls: Bool {
        let presentation = draftAppearance.presentation.effectivePresentation
        return isDevice || presentation == .roundedRectangleTag || presentation == .capsule
    }

    private func updateBackgroundVisibility() {
        let visible = showsBackgroundControls
        let custom = visible && draftAppearance.backgroundColorSource == .custom
        backgroundSourceRow?.isHidden = !visible
        backgroundRow?.isHidden = !custom
        backgroundTransparencyRow?.isHidden = !visible || draftAppearance.backgroundColorSource != .text
        if !custom { backgroundColorWell?.deactivate() }
    }

    private func updateBackgroundTransparencyValue(_ percentage: Double) {
        backgroundTransparencyValue?.stringValue = percentage.formatted(.number.precision(.fractionLength(0...2))) + "%"
    }

    @objc private func changeBackgroundTransparency(_ sender: NSSlider) {
        updateBackgroundTransparencyValue(sender.doubleValue)
        mutate { $0.backgroundOpacity = 1 - sender.doubleValue / 100 }
    }

    @objc private func changeBackgroundColor(_ sender: NSColorWell) {
        guard let color = RequestLogBackgroundColor(appKitColor: sender.color) else { return }
        mutate { $0.backgroundColor = color }
    }

    @objc private func resetBackgroundColor(_ sender: NSButton) {
        backgroundColorWell?.deactivate()
        backgroundColorWell?.color = .controlColor
        mutate { $0.backgroundColor = nil }
    }

    private func makeBorderRows() {
        let source = menu("边框颜色", values: RequestLogBorderColorSource.allCases,
                          selected: draftAppearance.borderColorSource, title: \.title) { $0.borderColorSource = $1 }
        let well = NSColorWell(frame: .zero)
        well.color = draftAppearance.borderColor?.appKitColor ?? .separatorColor
        well.target = self; well.action = #selector(changeBorderColor(_:))
        well.setAccessibilityLabel("自定义边框颜色")
        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetBorderColor(_:)))
        let picker = row("自定义颜色", NativeUI.stack([well, reset], vertical: false, spacing: 8))
        well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        well.heightAnchor.constraint(equalToConstant: 26).isActive = true
        addFullWidth(picker)

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal; formatter.allowsFloats = true
        formatter.minimum = 0.5; formatter.maximum = 8; formatter.maximumFractionDigits = 2
        let field = NSTextField()
        field.formatter = formatter; field.delegate = self
        field.doubleValue = draftAppearance.effectiveBorderWidth
        field.setAccessibilityLabel("边框粗细，pt，0.5 到 8")
        let stepper = NSStepper()
        stepper.minValue = 0.5; stepper.maxValue = 8; stepper.increment = 0.5
        stepper.valueWraps = false; stepper.doubleValue = draftAppearance.effectiveBorderWidth
        stepper.target = self; stepper.action = #selector(changeBorderWidth(_:))
        stepper.setAccessibilityLabel("调整边框粗细")
        let width = row("边框粗细", NativeUI.stack([field, stepper, NativeUI.label("pt", secondary: true)], vertical: false, spacing: 6))
        addFullWidth(width)
        borderRows = [source, picker, width]; borderColorRow = picker; borderColorWell = well
        borderWidthField = field; borderWidthStepper = stepper
    }

    private var parsedBorderWidth: Double? {
        guard let field = borderWidthField, let formatter = field.formatter as? NumberFormatter,
              let value = formatter.number(from: field.stringValue)?.doubleValue,
              value.isFinite, (0.5...8).contains(value) else { return nil }
        return value
    }

    private func updateBorderVisibility() {
        let visible = !isDevice && draftAppearance.presentation.isOutline
        for row in borderRows { row.isHidden = !visible }
        let custom = visible && draftAppearance.borderColorSource == .custom
        borderColorRow?.isHidden = !custom
        if !custom { borderColorWell?.deactivate() }
    }

    @objc private func changeBorderColor(_ sender: NSColorWell) {
        guard let color = RequestLogBackgroundColor(appKitColor: sender.color) else { return }
        mutate { $0.borderColor = color }
    }

    @objc private func resetBorderColor(_ sender: NSButton) {
        borderColorWell?.deactivate(); borderColorWell?.color = .separatorColor
        mutate { $0.borderColor = nil }
    }

    @objc private func changeBorderWidth(_ sender: NSStepper) {
        borderWidthField?.doubleValue = sender.doubleValue
        mutate { $0.borderWidth = sender.doubleValue }
    }

    @discardableResult
    private func menu<Value: Equatable>(_ label: String, values: [Value], selected: Value,
                                        title: KeyPath<Value, String>, change: @escaping (inout RequestLogContentAppearance, Value) -> Void) -> NSStackView {
        let control = RequestLogAppearancePopUp(titles: values.map { $0[keyPath: title] }) { [weak self] index in
            guard let self, values.indices.contains(index) else { return }
            mutate { change(&$0, values[index]) }
        }
        control.selectItem(at: values.firstIndex(of: selected) ?? 0)
        if #available(macOS 26.0, *) { control.borderShape = .capsule }
        control.setAccessibilityLabel(label)
        let result = row(label, control)
        addFullWidth(result)
        return result
    }

    private func toggle(_ label: String, selected: Bool, change: @escaping (inout RequestLogContentAppearance, Bool) -> Void) {
        let control = RequestLogAppearanceCheckbox { [weak self] selected in
            self?.mutate { change(&$0, selected) }
        }
        control.state = selected ? .on : .off
        control.setAccessibilityLabel(label)
        addFullWidth(row(label, control))
    }

    private func makeThresholdRow() {
        let field = NSTextField(string: String(draftAppearance.effectiveSlowThresholdMilliseconds))
        let formatter = NumberFormatter()
        formatter.numberStyle = .none; formatter.allowsFloats = false
        formatter.minimum = 1; formatter.maximum = 3_600_000
        field.formatter = formatter; field.delegate = self
        field.setAccessibilityLabel("慢请求阈值，毫秒")
        let control = NativeUI.stack([field, NativeUI.label("ms", secondary: true)], vertical: false, spacing: 6)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let threshold = row("阈值", control)
        thresholdField = field; thresholdRow = threshold
        addFullWidth(threshold)
    }

    private func updateThresholdVisibility() { thresholdRow?.isHidden = !draftAppearance.highlightsSlowRequests }

    private func mutate(_ change: (inout RequestLogContentAppearance) -> Void) {
        change(&draftAppearance)
        updateThresholdVisibility()
        updateBackgroundVisibility()
        updateBorderVisibility()
        onChange(draftAppearance)
        onValidationChange()
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === borderWidthField {
            if let width = parsedBorderWidth {
                borderWidthStepper?.doubleValue = width
                mutate { $0.borderWidth = width }
            } else { onValidationChange() }
            return
        }
        guard notification.object as? NSTextField === thresholdField, let thresholdField else { return }
        if let value = Int(thresholdField.stringValue), (1...3_600_000).contains(value) {
            mutate { $0.slowThresholdMilliseconds = value }
        } else { onValidationChange() }
    }

    private func row(_ title: String, _ control: NSView) -> NSStackView {
        let label = NativeUI.label(title)
        label.widthAnchor.constraint(equalToConstant: 74).isActive = true
        let row = NativeUI.stack([label, control], vertical: false, spacing: 8)
        row.distribution = .fill
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor)
        ])
        return row
    }

    private func addFullWidth(_ child: NSView) {
        addArrangedSubview(child)
        child.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
}

extension RequestLogBackgroundColor {
    var appKitColor: NSColor {
        NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }

    init?(appKitColor: NSColor) {
        guard let rgb = appKitColor.usingColorSpace(.sRGB) else { return nil }
        self.init(red: Double(rgb.redComponent), green: Double(rgb.greenComponent),
                  blue: Double(rgb.blueComponent), alpha: Double(rgb.alphaComponent))
    }
}

@MainActor
private final class RequestLogAppearancePopUp: NSPopUpButton {
    private let onChange: (Int) -> Void
    init(titles: [String], onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: titles)
        target = self; action = #selector(changed)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func changed() { onChange(indexOfSelectedItem) }
}

@MainActor
private final class RequestLogAppearanceCheckbox: NSButton {
    private let onChange: (Bool) -> Void
    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        setButtonType(.switch); title = "启用"
        target = self; action = #selector(changed)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func changed() { onChange(state == .on) }
}
