// Appended to the SAME copied production source file. Swift private members
// remain private in product code; only these test-only queue controls see them.
extension CaptureRecorder {
    func auditSend(_ frame: ARFrame) { delegateQueue.sync { session(ARSession(), didUpdate: frame) } }
    func auditInterrupt() { delegateQueue.sync { sessionWasInterrupted(ARSession()) } }
    func auditFail() {
        delegateQueue.sync {
            session(ARSession(), didFailWithError: CaptureError.invalid("synthetic AR failure"))
        }
    }
    func auditDrain() {
        delegateQueue.sync {}
        writerQueue.sync {}
        delegateQueue.sync {}
        writerQueue.sync {}
    }
    func auditState() -> (active: Bool, admitted: Int, root: URL?) {
        delegateQueue.sync { (active != nil, nextIndex - 1, active?.root) }
    }
    func auditBlockWriter() -> DispatchSemaphore {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        writerQueue.async { entered.signal(); release.wait() }
        precondition(entered.wait(timeout: .now() + 10) == .success)
        return release
    }
    func auditWriterAction(_ body: @escaping () -> Void) { writerQueue.async(execute: body) }
}
