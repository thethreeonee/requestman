import Foundation

/// A processor owns one modification's semantics; the engine owns ordering and commit.
protocol StepProcessor: Sendable {
    func requirements(for step: ModificationStep) -> StepExecutionRequirements
    func process(_ step: ModificationStep, draft: inout HTTPMessageDraft, context: ModificationExecutionContext) throws
    func processAsync(_ step: ModificationStep, draft: inout HTTPMessageDraft, context: ModificationExecutionContext) async throws
}

extension StepProcessor {
    func requirements(for step: ModificationStep) -> StepExecutionRequirements { .init() }
    func processAsync(_ step: ModificationStep, draft: inout HTTPMessageDraft, context: ModificationExecutionContext) async throws {
        try process(step, draft: &draft, context: context)
    }
}

struct StepExecutionRequirements {
    var input: StepInputRequirement = .metadataOnly
    var background = false
    var script = false
    var delay = false
    var bodyFile = false
}

enum StepProcessors {
    static func processor(for kind: ModificationKind) -> any StepProcessor {
        switch kind {
        case .setHeader, .removeHeader: HeaderProcessor()
        case .modifyJSON: JSONBodyProcessor()
        case .replaceBody: BodyProcessor()
        case .rewriteURL: URLRewriteProcessor()
        case .setQueryParameter: QueryParameterProcessor()
        case .replaceURLString: URLReplaceProcessor()
        case .setMethod: MethodProcessor()
        case .setStatus: StatusProcessor()
        case .mock: MockProcessor()
        case .redirect: RedirectProcessor()
        case .script: ScriptProcessor()
        case .delay: DelayProcessor()
        }
    }
}
