import Foundation

/// Verdict for MicCapture's start-of-capture silence watchdog. Pure decision so
/// it can be unit-tested offline; the hardware response (rebuilding the engine
/// without Voice-Processing I/O) lives in MicCapture and is covered by the live
/// `--probe-capture` gate.
enum CaptureSilenceAction: Equatable {
    /// Real audio has been observed — the mic is healthy, do nothing.
    case ok
    /// No buffers have arrived yet — the mic is still spinning up; not a
    /// silence verdict (never self-heal on this, it would thrash a slow mic).
    case waiting
    /// Buffers are arriving but every sample is silent AND the engine was built
    /// with VPIO on — the exact "meeting-AEC silenced the shared mic" signature.
    /// Rebuild the engine with voice processing off, once.
    case selfHeal
    /// Buffers are arriving but silent with VPIO already off (or we already
    /// self-healed once) — nothing left to auto-fix; surface it instead of
    /// discarding an empty take silently.
    case reportSilent
}

enum CaptureSilenceCheck {
    /// What the watchdog should do after the startup window elapses.
    /// - Parameters:
    ///   - buffersArrived: any audio buffer delivered since the engine started.
    ///   - sawSignal: at least one buffer rose above the silence floor.
    ///   - voiceProcessingActive: the running engine was built with VPIO on.
    ///   - alreadyHealed: we have already rebuilt once this session (loop guard).
    static func decide(buffersArrived: Bool,
                       sawSignal: Bool,
                       voiceProcessingActive: Bool,
                       alreadyHealed: Bool) -> CaptureSilenceAction {
        if sawSignal { return .ok }
        if !buffersArrived { return .waiting }
        // Buffers arrived, all silent:
        if voiceProcessingActive && !alreadyHealed { return .selfHeal }
        return .reportSilent
    }
}
