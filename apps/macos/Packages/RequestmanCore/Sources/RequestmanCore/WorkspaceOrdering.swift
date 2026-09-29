import Foundation

extension WorkspaceDocument {
    /// Insertion indices refer to the destination array before removing the source.
    /// Returns false for invalid destinations and moves that leave the order unchanged.
    @discardableResult
    public mutating func moveProject(_ id: UUID, to insertionIndex: Int) -> Bool {
        guard let source = projects.firstIndex(where: { $0.id == id }),
              (0...projects.count).contains(insertionIndex) else { return false }
        let destination = insertionIndex - (source < insertionIndex ? 1 : 0)
        guard source != destination else { return false }
        let project = projects.remove(at: source)
        projects.insert(project, at: destination)
        return true
    }

    /// Moves the original rule, preserving its identity, enabled state, conditions and steps.
    @discardableResult
    public mutating func moveWorkflow(_ id: UUID, from sourceProjectID: UUID,
                                      to destinationProjectID: UUID, at insertionIndex: Int) -> Bool {
        guard let sourceProject = projects.firstIndex(where: { $0.id == sourceProjectID }),
              let destinationProject = projects.firstIndex(where: { $0.id == destinationProjectID }),
              let source = projects[sourceProject].workflows.firstIndex(where: { $0.id == id }),
              (0...projects[destinationProject].workflows.count).contains(insertionIndex) else { return false }
        let destination = insertionIndex - (sourceProject == destinationProject && source < insertionIndex ? 1 : 0)
        guard sourceProject != destinationProject || source != destination else { return false }
        let workflow = projects[sourceProject].workflows.remove(at: source)
        projects[destinationProject].workflows.insert(workflow, at: destination)
        return true
    }
}
