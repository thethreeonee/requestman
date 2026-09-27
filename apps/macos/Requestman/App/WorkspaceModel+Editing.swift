import Foundation
import RequestmanCore

extension WorkspaceModel {
    var selectedStep: ModificationStep? {
        guard let workflow else { return nil }
        return (editingResponse ? workflow.responseSteps : workflow.requestSteps).first { $0.id == selectedStepID }
    }
    var workflow: RequestWorkflow? { document.projects.flatMap(\.workflows).first { $0.id == selectedWorkflowID } }
    var projectName: String { document.projects.first { $0.workflows.contains { $0.id == selectedWorkflowID } }?.name ?? "" }
    func updateWorkflow(_ workflow: RequestWorkflow) {
        for p in document.projects.indices {
            if let w = document.projects[p].workflows.firstIndex(where: { $0.id == workflow.id }) {
                document.projects[p].workflows[w] = workflow; return
            }
        }
    }
    func addProject() { let p = WorkflowProject(); document.projects.append(p); addWorkflow(projectID: p.id) }
    func addWorkflow(projectID: UUID) {
        guard let i = document.projects.firstIndex(where: { $0.id == projectID }) else { return }
        let workflow = RequestWorkflow(); document.projects[i].workflows.append(workflow)
        selectedWorkflowID = workflow.id; selectedStepID = nil
    }
    func addMockWorkflow(from record: CaptureRecord) {
        guard loaded else { return }
        let generation = workspaceGeneration
        Task { [weak self] in
            do {
                let workflow = try await Task.detached(priority: .userInitiated) {
                    try CapturedMockWorkflow.make(from: record, decodeBody: RequestBodyDecoding.decode)
                }.value
                guard let self, loaded, workspaceGeneration == generation else { return }
                if document.projects.isEmpty { document.projects.append(WorkflowProject()) }
                // Place before the first active matching rule so the new Mock can take effect.
                let match = RuleMatchingEngine.match(
                    document, method: record.method, url: record.url, headers: record.requestHeaders
                )
                let matchingIndex = match?.projectID.flatMap { projectID in
                    document.projects.firstIndex { $0.id == projectID }
                }
                let selectedIndex = document.projects.firstIndex {
                    $0.enabled && $0.workflows.contains { $0.id == selectedWorkflowID }
                }
                let index: Int
                if let existing = matchingIndex ?? selectedIndex ?? document.projects.firstIndex(where: \.enabled) {
                    index = existing
                } else {
                    document.projects.append(WorkflowProject()); index = document.projects.count - 1
                }
                document.projects[index].workflows.insert(workflow, at: 0)
                selectedWorkflowID = workflow.id
                selectedStepID = nil
                editingResponse = false
                history.selectedID = nil
                selection = .rules
            } catch { self?.errorMessage = "无法创建 Mock：\(error.localizedDescription)" }
        }
    }
    func deleteWorkflow(_ id: UUID) {
        for i in document.projects.indices { document.projects[i].workflows.removeAll { $0.id == id } }
        if selectedWorkflowID == id { selectedWorkflowID = nil; selectedStepID = nil }
    }
    func duplicateWorkflow(_ workflow: RequestWorkflow, projectID: UUID) {
        guard let i = document.projects.firstIndex(where: { $0.id == projectID }) else { return }
        var copy = workflow.duplicated(); copy.name += " 副本"
        document.projects[i].workflows.append(copy); selectedWorkflowID = copy.id; selectedStepID = nil
    }
    func duplicateProject(_ id: UUID) {
        guard let project = document.projects.first(where: { $0.id == id }) else { return }
        var copy = project.duplicated(); copy.name += " 副本"
        document.projects.append(copy)
        selectedWorkflowID = copy.workflows.first?.id; selectedStepID = nil
    }

    func addStep(_ kind: ModificationKind, response: Bool) {
        guard var workflow else { return }
        var step = ModificationStep(kind: kind)
        if kind == .script { step.value = response ? "// 修改响应后返回 response\nreturn response;" : "// 修改请求后返回 request\nreturn request;" }
        if response { workflow.responseSteps.append(step) } else { workflow.requestSteps.append(step) }
        updateWorkflow(workflow); editingResponse = response; selectedStepID = step.id
    }
    func addEnvironment() {
        let env = WorkspaceEnvironment(name: "新环境"); document.environments.append(env); selectedEnvironmentID = env.id
        if document.selectedEnvironmentID == nil { document.selectedEnvironmentID = env.id }
    }}
