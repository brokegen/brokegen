import Foundation
import IOKit.pwr_mgt

class StayAwake {
    var pmAssertionID: IOPMAssertionID = 0
    var assertionIsActive: Bool = false

    var noSleepReturn: IOReturn? // Could probably be replaced by a boolean value, for example 'isBlockingSleep', just make sure 'IOPMAssertionRelease' doesn't get called, if 'IOPMAssertionCreateWithName' failed.

    init(reason: String) throws {
        let result = self.createAssertion(reason: reason)
        if !result {
            throw NSError(
                domain: "StayAwake failed, original reason: \(reason)",
                code: 0)
        }
    }

    deinit {
        _ = self.destroyAssertion()
    }

    func createAssertion(reason: String) -> Bool {
        guard !assertionIsActive else { return false }

        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &pmAssertionID)
        if result == kIOReturnSuccess {
            assertionIsActive = true
        }

        return assertionIsActive
    }

    func destroyAssertion() -> Bool {
        if assertionIsActive {
            _ = IOPMAssertionRelease(pmAssertionID) == kIOReturnSuccess
            pmAssertionID = 0
            assertionIsActive = false
            return true
        }

        return false
    }
}

class StayAwakeService: Job {
    var stayAwake: StayAwake?

    override init() {
        super.init()
        sidebarTitle = "stay awake"
        ribbonText = "StayAwakeService: PreventUserIdleSystemSleep\n(keep macOS awake while this job is running)"

        displayedStatus = String(describing: JobStatus.notStarted)
        displayedOutput = ""
    }

    override func launch() -> StayAwakeService {
        guard stayAwake == nil else { return self }

        status = .requestedStart

        do {
            stayAwake = try StayAwake(reason: "user-controlled Brokegen Job")
            let success = stayAwake!.createAssertion(reason: "called launch")
            if !success {
                stayAwake = nil
                status = .error("failed to create wakelock")
            }
        }
        catch {
            stayAwake = nil
            status = .error("failed to construct wakelocker")
        }

        status = .startedWithOutput
        displayedStatus = "\(Date.now): Started OK"
        displayedOutput += "\(Date.now): Started OK\n"
        return self
    }

    override func terminatePatiently() -> StayAwakeService {
        status = .requestedStop
        _ = stayAwake?.destroyAssertion()
        stayAwake = nil
        status = .stopped
        displayedStatus = "\(Date.now): Stopped"
        displayedOutput += "\(Date.now): Stopped\n"
        return self
    }
}
