import Foundation

#if os(macOS)
import IOKit.pwr_mgt

/// Assertion changes can be seen with `/usr/bin/pmset -g assertionslog`
class StayAwake {
    var pmAssertionID: IOPMAssertionID = 0
    var assertionIsActive: Bool = false

    deinit {
        _ = self.destroyAssertion()
    }

    /// It's not entirely clear what assertion(s) to use to keep Ollama running in the background.
    /// `caffeinate -dut 3600` works to keep the system awake for a while, but can we avoid keeping the display on?
    ///
    /// - kIOPMAssertionTypePreventUserIdleSystemSleep: in testing, previous iteration had a double-init error
    /// - kIOPMAssertionTypeNoIdleSleep: TODO
    /// - kIOPMAssertionTypeNoDisplaySleep: TODO
    /// - kIOPMAssertionTypePreventUserIdleDisplaySleep: TODO
    ///
    func createAssertion(reason: String) -> (Bool, IOReturn?) {
        guard !assertionIsActive else { return (false, nil) }

        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &pmAssertionID)
        if result == kIOReturnSuccess {
            assertionIsActive = true
        }

        return (result == kIOReturnSuccess, result)
    }

    func destroyAssertion() -> (Bool, IOReturn?) {
        if assertionIsActive {
            let result = IOPMAssertionRelease(pmAssertionID)
            pmAssertionID = 0
            assertionIsActive = false
            return (result == kIOReturnSuccess, result)
        }

        return (false, nil)
    }
}
#endif

#if os(iOS)
class StayAwake {
    deinit {
        _ = self.destroyAssertion()
    }

    func createAssertion(reason: String) -> (Bool, String?) {
        UIApplication.shared.isIdleTimerDisabled = true
        return (true, nil)
    }

    func destroyAssertion() -> (Bool, String?) {
        // TODO: Race condition if we have two instances working
        return (true, nil)
    }
}
#endif

class StayAwakeService: Job {
    var stayAwake: StayAwake = StayAwake()

    override init() {
        super.init()
        sidebarTitle = "stay awake"
        ribbonText = "StayAwakeService: PreventUserIdleSystemSleep\n(keep macOS awake while this job is running)"

        displayedOutput = ""
    }

    override func launch() -> StayAwakeService {
        status = .requestedStart

        let (success, result) = stayAwake.createAssertion(reason: "brokegen StayAwakeService")
        if !success {
            status = .error("failed to create wakelock: \(result)")
            displayedOutput += "\(Date.now): failed to create wakelock: \(result)\n"
        }
        else {
            status = .startedWithOutput
            displayedOutput += "\(Date.now): Started OK\n"
        }

        return self
    }

    override func terminatePatiently() -> StayAwakeService {
        status = .requestedStop
        _ = stayAwake.destroyAssertion()
        status = .stopped
        displayedOutput += "\(Date.now): Stopped\n"
        return self
    }
}
