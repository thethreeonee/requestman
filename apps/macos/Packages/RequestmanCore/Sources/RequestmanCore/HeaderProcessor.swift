import Foundation

struct HeaderProcessor: StepProcessor {
    func process(_ step: ModificationStep, draft: inout HTTPMessageDraft, context: ModificationExecutionContext) throws {
        func resolveValue(_ text: String) throws -> String { try context.resolve(text, step: step) }
        // Stage sequential edits so a later invalid entry cannot partially change the draft.
        var headers = draft.headers
        for entry in step.headerEntries {
            try HTTPMessageValidation.validateHeader(entry.name, value: "")
            let matches = headers.indices.filter { headers[$0].name.caseInsensitiveCompare(entry.name) == .orderedSame }
            switch entry.operation {
            case .remove:
                headers.removeAll { $0.name.caseInsensitiveCompare(entry.name) == .orderedSame }
            case .modify:
                guard !matches.isEmpty else { continue }
                let value = try resolveValue(entry.value)
                try HTTPMessageValidation.validateHeader(entry.name, value: value)
                for index in matches { headers[index].value = value }
            case .add:
                let value = try resolveValue(entry.value)
                try HTTPMessageValidation.validateHeader(entry.name, value: value)
                headers.append(HTTPField(entry.name, value))
            case .set, nil:
                let value = try resolveValue(entry.value)
                try HTTPMessageValidation.validateHeader(entry.name, value: value)
                headers.removeAll { $0.name.caseInsensitiveCompare(entry.name) == .orderedSame }
                headers.append(HTTPField(entry.name, value))
            }
        }
        draft.headers = headers
    }
}
