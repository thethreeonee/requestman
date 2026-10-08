import Foundation

public enum RequestLogContentPresentation: String, CaseIterable, Codable, Sendable {
    case automatic, plainText, roundedRectangleTag, capsule, roundedRectangleBorder, capsuleBorder

    public static let selectableCases: [Self] = [.plainText, .roundedRectangleTag, .capsule, .roundedRectangleBorder, .capsuleBorder]
    /// Keep the saved legacy value intact while displaying its existing text style.
    public var effectivePresentation: Self { self == .automatic ? .plainText : self }
    public var isOutline: Bool { self == .roundedRectangleBorder || self == .capsuleBorder }

    public var title: String {
        switch self {
        case .automatic: "自动"
        case .plainText: "纯文字"
        case .roundedRectangleTag: "圆角标签"
        case .capsule: "胶囊"
        case .roundedRectangleBorder: "圆角边框"
        case .capsuleBorder: "胶囊边框"
        }
    }
}

public enum RequestLogBackgroundColorSource: String, CaseIterable, Codable, Sendable {
    case custom, text
    public var title: String {
        switch self {
        case .custom: "自定义"
        case .text: "跟随文本"
        }
    }
}

public enum RequestLogBorderColorSource: String, CaseIterable, Codable, Sendable {
    case text, custom
    public var title: String {
        switch self {
        case .text: "跟随文本"
        case .custom: "自定义"
        }
    }
}

public enum RequestLogFont: String, CaseIterable, Codable, Sendable {
    case automatic, system, monospaced
    public var title: String {
        switch self {
        case .automatic: "自动"
        case .system: "系统字体"
        case .monospaced: "等宽字体"
        }
    }
}

public enum RequestLogFontWeight: String, CaseIterable, Codable, Sendable {
    case automatic, regular, medium, semibold
    public var title: String {
        switch self {
        case .automatic: "自动"
        case .regular: "常规"
        case .medium: "中等"
        case .semibold: "半粗"
        }
    }
}

public enum RequestLogTruncation: String, CaseIterable, Codable, Sendable {
    case automatic, none, middle, tail
    public var title: String {
        switch self {
        case .automatic: "自动"
        case .none: "不省略"
        case .middle: "中间省略"
        case .tail: "末尾省略"
        }
    }
}

public enum RequestLogTimePrecision: String, CaseIterable, Codable, Sendable {
    case seconds, milliseconds
    public var title: String {
        switch self {
        case .seconds: "秒"
        case .milliseconds: "毫秒"
        }
    }
}

public enum RequestLogDurationUnit: String, CaseIterable, Codable, Sendable {
    case automatic, milliseconds, seconds
    public var title: String {
        switch self {
        case .automatic: "自动"
        case .milliseconds: "毫秒"
        case .seconds: "秒"
        }
    }
}

public enum RequestLogDecimalPrecision: String, CaseIterable, Codable, Sendable {
    case automatic, whole, tenths, hundredths
    public var title: String {
        switch self {
        case .automatic: "自动"
        case .whole: "整数"
        case .tenths: "一位小数"
        case .hundredths: "两位小数"
        }
    }
}

public enum RequestLogRuleSeparator: String, CaseIterable, Codable, Sendable {
    case automatic, dot, slash, arrow, newLine
    public var title: String {
        switch self {
        case .automatic: "自动"
        case .dot: "圆点"
        case .slash: "斜线"
        case .arrow: "箭头"
        case .newLine: "换行"
        }
    }
}

public enum RequestLogRepeatedValues: String, CaseIterable, Codable, Sendable {
    case singleLine, multipleLines
    public var title: String {
        switch self {
        case .singleLine: "单行"
        case .multipleLines: "多行"
        }
    }
}

/// Portable sRGB components shared by background and border colors.
public struct RequestLogBackgroundColor: Equatable, Codable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.component(red)
        self.green = Self.component(green)
        self.blue = Self.component(blue)
        self.alpha = Self.component(alpha)
    }

    private static func component(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }

    private enum CodingKeys: String, CodingKey { case red, green, blue, alpha }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(red: try values.decode(Double.self, forKey: .red),
                  green: try values.decode(Double.self, forKey: .green),
                  blue: try values.decode(Double.self, forKey: .blue),
                  alpha: try values.decodeIfPresent(Double.self, forKey: .alpha) ?? 1)
    }
}

/// Appearance belongs to each content instance and survives changing its field.
/// Typed options remain saved when their field is not currently selected.
public struct RequestLogContentAppearance: Equatable, Codable, Sendable {
    public var presentation: RequestLogContentPresentation
    public var backgroundColor: RequestLogBackgroundColor?
    public var backgroundColorSource: RequestLogBackgroundColorSource
    /// Applies only when the background follows text; custom RGBA retains its own alpha.
    public var backgroundOpacity: Double
    public var borderColorSource: RequestLogBorderColorSource
    public var borderColor: RequestLogBackgroundColor?
    public var borderWidth: Double
    public var usesSemanticColors: Bool
    public var font: RequestLogFont
    public var weight: RequestLogFontWeight
    public var truncation: RequestLogTruncation
    public var emphasizesHost: Bool
    public var showsStatusDescription: Bool
    public var emphasizesErrors: Bool
    public var timePrecision: RequestLogTimePrecision
    public var durationUnit: RequestLogDurationUnit
    public var durationPrecision: RequestLogDecimalPrecision
    public var highlightsSlowRequests: Bool
    public var slowThresholdMilliseconds: Int
    public var ruleSeparator: RequestLogRuleSeparator
    public var repeatedValues: RequestLogRepeatedValues
    public var showsValueCount: Bool

    /// Bound the effective value without rewriting imported or saved configuration.
    public var effectiveSlowThresholdMilliseconds: Int { min(max(slowThresholdMilliseconds, 1), 3_600_000) }
    public var effectiveBorderWidth: Double { borderWidth.isFinite ? min(max(borderWidth, 0.5), 8) : 1 }
    public var effectiveBackgroundOpacity: Double { backgroundOpacity.isFinite ? min(max(backgroundOpacity, 0), 1) : 0.15 }

    public init(presentation: RequestLogContentPresentation = .automatic, usesSemanticColors: Bool = true,
                font: RequestLogFont = .automatic, weight: RequestLogFontWeight = .automatic,
                truncation: RequestLogTruncation = .automatic, emphasizesHost: Bool = false,
                showsStatusDescription: Bool = false, emphasizesErrors: Bool = true,
                timePrecision: RequestLogTimePrecision = .seconds, durationUnit: RequestLogDurationUnit = .automatic,
                durationPrecision: RequestLogDecimalPrecision = .automatic, highlightsSlowRequests: Bool = false,
                slowThresholdMilliseconds: Int = 1000, ruleSeparator: RequestLogRuleSeparator = .automatic,
                repeatedValues: RequestLogRepeatedValues = .singleLine, showsValueCount: Bool = false,
                backgroundColor: RequestLogBackgroundColor? = nil,
                backgroundColorSource: RequestLogBackgroundColorSource = .custom, backgroundOpacity: Double = 0.15,
                borderColorSource: RequestLogBorderColorSource = .text,
                borderColor: RequestLogBackgroundColor? = nil, borderWidth: Double = 1) {
        self.presentation = presentation; self.usesSemanticColors = usesSemanticColors
        self.backgroundColor = backgroundColor
        self.backgroundColorSource = backgroundColorSource; self.backgroundOpacity = backgroundOpacity
        self.borderColorSource = borderColorSource; self.borderColor = borderColor; self.borderWidth = borderWidth
        self.font = font; self.weight = weight; self.truncation = truncation
        self.emphasizesHost = emphasizesHost; self.showsStatusDescription = showsStatusDescription
        self.emphasizesErrors = emphasizesErrors; self.timePrecision = timePrecision
        self.durationUnit = durationUnit; self.durationPrecision = durationPrecision
        self.highlightsSlowRequests = highlightsSlowRequests; self.slowThresholdMilliseconds = slowThresholdMilliseconds
        self.ruleSeparator = ruleSeparator; self.repeatedValues = repeatedValues; self.showsValueCount = showsValueCount
    }

    private enum CodingKeys: String, CodingKey {
        case presentation, backgroundColor, usesSemanticColors, font, weight, truncation, emphasizesHost, showsStatusDescription
        case emphasizesErrors, timePrecision, durationUnit, durationPrecision, highlightsSlowRequests
        case slowThresholdMilliseconds, ruleSeparator, repeatedValues, showsValueCount
        case borderColorSource, borderColor, borderWidth
        case backgroundColorSource, backgroundOpacity
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        presentation = try values.decodeIfPresent(RequestLogContentPresentation.self, forKey: .presentation) ?? .automatic
        backgroundColor = try values.decodeIfPresent(RequestLogBackgroundColor.self, forKey: .backgroundColor)
        backgroundColorSource = try values.decodeIfPresent(RequestLogBackgroundColorSource.self, forKey: .backgroundColorSource) ?? .custom
        backgroundOpacity = try values.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0.15
        borderColorSource = try values.decodeIfPresent(RequestLogBorderColorSource.self, forKey: .borderColorSource) ?? .text
        borderColor = try values.decodeIfPresent(RequestLogBackgroundColor.self, forKey: .borderColor)
        borderWidth = try values.decodeIfPresent(Double.self, forKey: .borderWidth) ?? 1
        usesSemanticColors = try values.decodeIfPresent(Bool.self, forKey: .usesSemanticColors) ?? true
        font = try values.decodeIfPresent(RequestLogFont.self, forKey: .font) ?? .automatic
        weight = try values.decodeIfPresent(RequestLogFontWeight.self, forKey: .weight) ?? .automatic
        truncation = try values.decodeIfPresent(RequestLogTruncation.self, forKey: .truncation) ?? .automatic
        emphasizesHost = try values.decodeIfPresent(Bool.self, forKey: .emphasizesHost) ?? false
        showsStatusDescription = try values.decodeIfPresent(Bool.self, forKey: .showsStatusDescription) ?? false
        emphasizesErrors = try values.decodeIfPresent(Bool.self, forKey: .emphasizesErrors) ?? true
        timePrecision = try values.decodeIfPresent(RequestLogTimePrecision.self, forKey: .timePrecision) ?? .seconds
        durationUnit = try values.decodeIfPresent(RequestLogDurationUnit.self, forKey: .durationUnit) ?? .automatic
        durationPrecision = try values.decodeIfPresent(RequestLogDecimalPrecision.self, forKey: .durationPrecision) ?? .automatic
        highlightsSlowRequests = try values.decodeIfPresent(Bool.self, forKey: .highlightsSlowRequests) ?? false
        slowThresholdMilliseconds = try values.decodeIfPresent(Int.self, forKey: .slowThresholdMilliseconds) ?? 1000
        ruleSeparator = try values.decodeIfPresent(RequestLogRuleSeparator.self, forKey: .ruleSeparator) ?? .automatic
        repeatedValues = try values.decodeIfPresent(RequestLogRepeatedValues.self, forKey: .repeatedValues) ?? .singleLine
        showsValueCount = try values.decodeIfPresent(Bool.self, forKey: .showsValueCount) ?? false
    }
}
