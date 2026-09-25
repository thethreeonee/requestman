import Observation

enum InspectionVersion: String, CaseIterable, Sendable {
    case original, final, difference

    var title: String {
        switch self {
        case .original: "修改前"
        case .final: "修改后"
        case .difference: "修改对比"
        }
    }
}

/// The toolbar and all request/response panes share one display mode.
@MainActor @Observable
final class RequestInspectionMode {
    var version: InspectionVersion = .final
}
