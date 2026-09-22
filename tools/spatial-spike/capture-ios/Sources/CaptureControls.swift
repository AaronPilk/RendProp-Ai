// The real controller uses this lifecycle to prevent another start while the
// current capture is saving or its files are being checked for export.
struct CaptureControls {
    enum Phase: Equatable {
        case ready, preparing, recording, saving, finished(exportable: Bool), verifyingExport, closed
    }
    private(set) var phase: Phase = .ready

    var startEnabled: Bool {
        switch phase { case .ready, .finished: return true; default: return false }
    }
    var stopEnabled: Bool { phase == .recording }
    var exportEnabled: Bool { phase == .finished(exportable: true) }
    var isRecording: Bool { phase == .recording }
    var isClosed: Bool { phase == .closed }

    // Closing during permission/file preparation or recording must interrupt.
    // An already-requested save is allowed to drain; it is never deleted or
    // promoted to success by a late UI callback. Closing is terminal/idempotent.
    @discardableResult mutating func endPresentation() -> Bool {
        let shouldInterrupt = phase == .preparing || phase == .recording
        phase = .closed
        return shouldInterrupt
    }

    @discardableResult mutating func beginStart() -> Bool {
        guard startEnabled else { return false }
        phase = .preparing
        return true
    }
    mutating func startFailed() {
        guard phase == .preparing else { return }
        phase = .ready
    }
    @discardableResult mutating func captureStarted() -> Bool {
        guard phase == .preparing else { return false }
        phase = .recording
        return true
    }
    @discardableResult mutating func beginStop() -> Bool {
        guard isRecording else { return false }
        phase = .saving
        return true
    }
    mutating func captureFinished(exportable: Bool) {
        guard phase == .preparing || phase == .recording || phase == .saving else { return }
        phase = .finished(exportable: exportable)
    }
    @discardableResult mutating func beginExport() -> Bool {
        guard exportEnabled else { return false }
        phase = .verifyingExport
        return true
    }
    @discardableResult mutating func beginSavedExport() -> Bool {
        guard startEnabled else { return false }
        phase = .verifyingExport
        return true
    }
    mutating func exportChecked(valid: Bool) {
        guard phase == .verifyingExport else { return }
        phase = .finished(exportable: valid)
    }
}
