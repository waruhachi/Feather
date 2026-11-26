// Adapted from KorSign (GPL-3.0).
import Foundation
import ObjectiveC

/// Read-only LaunchServices evidence. Missing selectors/data mean unverified, not success.
final class InstalledAppProbe {
    // One probe per installer, read serially. LaunchServices removes its lookup
    // before callers necessarily sample the final update on this live object.
    private var lastProgress: Progress?

    static func open(_ identifier: String) -> Bool {
        let selector = NSSelectorFromString("defaultWorkspace")
        let openSelector = NSSelectorFromString("openApplicationWithBundleID:")
        guard let type = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              type.responds(to: selector),
              let workspace = type.perform(selector)?.takeUnretainedValue() as? NSObject,
              workspace.responds(to: openSelector),
              let implementation = workspace.method(for: openSelector)
        else { return false }
        let call = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector, NSString) -> Bool).self)
        return call(workspace, openSelector, identifier as NSString)
    }

    func resetProgress() { lastProgress = nil }
    func read(_ identifier: String) -> (record: InstalledAppRecord?, progress: InstallProgressReading?) {
        let progress = readProgress(identifier)
        let selector = NSSelectorFromString("applicationProxyForIdentifier:")
        guard let type = NSClassFromString("LSApplicationProxy") as? NSObject.Type,
              type.responds(to: selector),
              let proxy = type.perform(selector, with: identifier)?.takeUnretainedValue() as? NSObject
        else { return (nil, progress) }

        func object(_ name: String) -> AnyObject? {
            let selector = NSSelectorFromString(name)
            guard proxy.responds(to: selector) else { return nil }
            return proxy.perform(selector)?.takeUnretainedValue()
        }
        func boolean(_ name: String) -> Bool? {
            let selector = NSSelectorFromString(name)
            guard proxy.responds(to: selector), let implementation = proxy.method(for: selector) else { return nil }
            // BOOL is a scalar; perform(_:)'s object return convention cannot read it.
            let call = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
            return call(proxy, selector)
        }

        guard let installed = boolean("isInstalled"), let placeholder = boolean("isPlaceholder") else {
            return (nil, progress)
        }
        return (InstalledAppRecord(
            isInstalled: installed, isPlaceholder: placeholder,
            version: object("shortVersionString") as? String,
            build: object("bundleVersion") as? String,
            bundleURL: object("bundleURL") as? URL,
            registeredDate: object("registeredDate") as? Date
        ), progress)
    }

    /// The workspace API was the working progress source on the jailed phone.
    /// Proxy.installProgress can remain nil even while an installation is running.
    private func readProgress(_ identifier: String) -> InstallProgressReading? {
        let workspaceSelector = NSSelectorFromString("defaultWorkspace")
        let progressSelector = NSSelectorFromString("installProgressForBundleID:makeSynchronous:")
        guard let type = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              type.responds(to: workspaceSelector),
              let workspace = type.perform(workspaceSelector)?.takeUnretainedValue() as? NSObject,
              workspace.responds(to: progressSelector),
              let implementation = workspace.method(for: progressSelector) else { return nil }
        // The second argument is an unsigned char, not an Objective-C object.
        let call = unsafeBitCast(implementation, to: (@convention(c)
            (AnyObject, Selector, NSString, UInt8) -> Unmanaged<AnyObject>?).self)
        let current = call(workspace, progressSelector, identifier as NSString, 1)?.takeUnretainedValue() as? Progress
        if let current { lastProgress = current }
        guard let progress = current ?? lastProgress else { return nil }
        let info = progress.userInfo
        let phase = (info[ProgressUserInfoKey("installPhase")] as? NSNumber)?.uintValue
        let state = (info[ProgressUserInfoKey("installState")] as? NSNumber)?.uintValue
        let expectedPhaseSelector = NSSelectorFromString("ls_expectedFinalInstallPhase")
        var expectedPhase: UInt?
        if progress.responds(to: expectedPhaseSelector), let implementation = progress.method(for: expectedPhaseSelector) {
            let getter = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> UInt).self)
            expectedPhase = getter(progress, expectedPhaseSelector)
        }
        var stateName: String?
        let nameSelector = NSSelectorFromString("NSStringFromLSInstallState:")
        if let state, let method = class_getClassMethod(NSString.self, nameSelector) {
            let stringify = unsafeBitCast(method_getImplementation(method), to: (@convention(c)
                (AnyObject, Selector, UInt) -> Unmanaged<AnyObject>?).self)
            stateName = stringify(NSString.self, nameSelector, state)?.takeUnretainedValue() as? String
        }
        return InstallProgressReading(fraction: progress.fractionCompleted,
            isFinished: progress.isFinished, isCancelled: progress.isCancelled,
            isCurrent: current != nil, installPhase: phase, expectedFinalPhase: expectedPhase,
            installState: state, installStateName: stateName)

    }

}
