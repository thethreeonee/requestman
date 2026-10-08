import Foundation

public enum RequestLogContentPresentation: String, CaseIterable, Codable, Sendable {
    case automatic, plainText, roundedRectangleTag, capsule

    public static let selectableCases: [Self] = [.plainText, .roundedRectangleTag, .capsule]
    /// Keep the saved legacy value intact while displaying its existing text style.
    public var effectivePresentation: Self { self == .automatic ? .plainText : self }

    public var title: String {
        switch self {
        case .automatic: "自动"
        case .plainText: "纯文字"
        case .roundedRectangleTag: "圆角标签"
        case .capsule: "胶囊"
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

/// Portable sRGB components; nil on the appearance preserves the native background.
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

    public init(presentation: RequestLogContentPresentation = .automatic, usesSemanticColors: Bool = true,
                font: RequestLogFont = .automatic, weight: RequestLogFontWeight = .automatic,
                truncation: RequestLogTruncation = .automatic, emphasizesHost: Bool = false,
                showsStatusDescription: Bool = false, emphasizesErrors: Bool = true,
                timePrecision: RequestLogTimePrecision = .seconds, durationUnit: RequestLogDurationUnit = .automatic,
                durationPrecision: RequestLogDecimalPrecision = .automatic, highlightsSlowRequests: Bool = false,
                slowThresholdMilliseconds: Int = 1000, ruleSeparator: RequestLogRuleSeparator = .automatic,
                repeatedValues: RequestLogRepeatedValues = .singleLine, showsValueCount: Bool = false,
                backgroundColor: RequestLogBackgroundColor? = nil) {
        self.presentation = presentation; self.usesSemanticColors = usesSemanticColors
        self.backgroundColor = backgroundColor
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
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        presentation = try values.decodeIfPresent(RequestLogContentPresentation.self, forKey: .presentation) ?? .automatic
        backgroundColor = try values.decodeIfPresent(RequestLogBackgroundColor.self, forKey: .backgroundColor)
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
