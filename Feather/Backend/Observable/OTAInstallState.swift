// Adapted from KorSign (GPL-3.0).
import Foundation

/// OTA has no cancellation callback. Timeouts are failures, never user cancellations.
struct OTAInstallState {
    enum Phase: Int { case idle, waiting, downloading, verifying, finished }
    private(set) var phase = Phase.idle
    private(set) var deadline: TimeInterval?
    private var sawProgress = false
    private var missingProgressSince: TimeInterval?

    func confirmsInstall(_ reading: InstallProgressReading?) -> Bool {
        guard phase == .verifying, sawProgress, let reading, !reading.isCancelled,
              reading.installStateName == "Finished", let finalPhase = reading.expectedFinalPhase,
              finalPhase == 1 || finalPhase == 2, // Installing or restoring app data, never a placeholder/download.
              reading.installPhase == finalPhase else { return false }
        return true
    }

    /// Progress ending retires the UI; it does not prove installation or authorize deletion.
    mutating func progressEnded(_ reading: InstallProgressReading?, now: TimeInterval) -> Bool {
        guard phase == .downloading || phase == .verifying else { return false }
        if let reading, reading.isCancelled { return false }
        if reading?.isCurrent == true, let fraction = reading?.fraction, fraction.isFinite, fraction > 0 {
            missingProgressSince = nil
            if reading?.isFinished == true { return phase == .verifying && sawProgress }
            sawProgress = true
            return false
        }
        guard phase == .verifying, sawProgress else { return false }
        if missingProgressSince == nil { missingProgressSince = now }
        return now - missingProgressSince! >= 1
    }

    mutating func advance(to next: Phase, now: TimeInterval) {
        guard next.rawValue > phase.rawValue else { return }
        phase = next
        switch next {
        case .waiting: deadline = now + 120
        case .downloading, .verifying: deadline = now + 600
        case .idle, .finished: deadline = nil
        }
    }

    func timedOut(at now: TimeInterval) -> Bool {
        deadline.map { now >= $0 } ?? false
    }
}

struct InstalledAppRecord: Equatable {
    let isInstalled: Bool
    let isPlaceholder: Bool
    let version: String?
    let build: String?
    let bundleURL: URL?
    let registeredDate: Date?

    func confirmsReplacement(of previous: Self?, version expectedVersion: String?, build expectedBuild: String?) -> Bool {
        guard let previous, isInstalled, !isPlaceholder,
              let expectedVersion, version == expectedVersion,
              let expectedBuild, build == expectedBuild,
              let bundleURL else { return false }
        if !previous.isInstalled { return true }
        // Same-version reinstalls must replace the old registration too.
        return (previous.bundleURL != nil && bundleURL != previous.bundleURL)
            || (registeredDate != nil && previous.registeredDate != nil && registeredDate != previous.registeredDate)
    }
}

struct InstallProgressReading: Equatable {
    let fraction: Double
    let isFinished: Bool
    let isCancelled: Bool
    var isCurrent: Bool = true
    var installPhase: UInt? = nil
    var expectedFinalPhase: UInt? = nil
    var installState: UInt? = nil
    var installStateName: String? = nil
}
