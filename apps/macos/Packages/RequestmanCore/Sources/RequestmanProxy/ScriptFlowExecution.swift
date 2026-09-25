import Foundation
import RequestmanCore

/// A lease bounds buffered script flows as well as workers. No queue grows with traffic.
final class ScriptFlowLease: Sendable {
    private static let slots = DispatchSemaphore(value: 4)
    static func acquire() -> ScriptFlowLease? {
        slots.wait(timeout: .now()) == .success ? ScriptFlowLease() : nil
    }
    let control = ScriptExecutionControl()
    private init() {}
    deinit { Self.slots.signal() }
}
