import Combine
import SwiftUI

/// Simplest job type, runs a Timer to print some text.
/// Moste useful for quick testing.
class TimeJob: Job {
    let timeInterval: TimeInterval
    let maxTimesFired: Int

    var currentTimesFired: Int = 0

    var timer: Timer? = nil

    init(_ label: String, timeInterval: TimeInterval = 5, maxTimesFired: Int = 24) {
        self.timeInterval = timeInterval
        self.maxTimesFired = maxTimesFired

        super.init()

        sidebarTitle = label
        ribbonText = label

        displayedOutput = ""
    }

    override func launch() -> TimeJob {
        guard timer == nil else { return self }
        status = .requestedStart
        displayedOutput += "\n"

        if maxTimesFired == 0 {
            return terminate(because: "started with maxTimesFired: 0")
        }

        timer = Timer.scheduledTimer(withTimeInterval: timeInterval, repeats: true) { timer in
            if self.maxTimesFired > 0 {
                if self.currentTimesFired >= self.maxTimesFired {
                    _ = self.terminate(because: "exceeded max timer incidents")
                    return
                }
            }

            if self.status == .requestedStop {
                _ = self.terminate(because: "finally detected stop request")
                return
            }

            self.displayedOutput += "\(Date.now): timer firing, #\(self.currentTimesFired)\n"
            self.currentTimesFired += 1
            self.status = .startedWithOutput
        }

        status = .startedNoOutput
        return self
    }

    override func terminate() -> TimeJob {
        return self.terminate(because: "impatient terminate request")
    }

    private func terminate(because reason: String?) -> TimeJob {
        if reason != nil {
            self.displayedOutput += "\(Date.now): terminating because \(reason!)"
        }

        timer?.invalidate()
        timer = nil

        status = .stopped
        return self
    }
}
