import Combine
import SwiftUI


enum JobStatus {
    case notStarted
    case requestedStart
    case startedNoOutput
    case startedWithOutput
    case requestedStop
    case stopped
    case error
}

class Job: ObservableObject, Identifiable {
    let id: UUID = UUID()

    @Published var status: JobStatus
    @Published var sidebarTitle: String

    var ribbonText: String = "[ribbonText]"

    /// Additional text describing Job status, intended to be the header area of a View.
    /// Should describe broad context, like whether the job is running, when it was last updated, etc.
    var displayedStatus: String = ""
    @Published var displayedOutput: String

    init() {
        status = .notStarted
        sidebarTitle = "[sidebarTitle]"
        displayedOutput = "[base Job, not initialized]\n"
    }

    func launch() {
        status = .error
        displayedOutput += "[base Job launched, but this should be overridden]\n"
    }

    func terminate() {
        status = .stopped
    }

    func terminatePatiently() {
        status = .requestedStop
    }
}

extension Job {
    func status(_ status: JobStatus) -> Job {
        self.status = status
        return self
    }
}

/// Simplest job type, runs a Timer to print some text.
/// Moste useful for quick testing.
class TimeJob: Job {
    let label: String
    let timeInterval: TimeInterval
    let maxTimesFired: Int

    var currentTimesFired: Int = 0
    private var displayStatusUpdates: AnyCancellable? = nil

    var timer: Timer? = nil

    init(_ label: String, timeInterval: TimeInterval = 5, maxTimesFired: Int = 24) {
        self.label = label
        self.timeInterval = timeInterval
        self.maxTimesFired = maxTimesFired

        super.init()

        self.displayedOutput = ""

        displayStatusUpdates = self.$status
            .sink { newStatus in
                self.sidebarTitle = "\(self.label) — \(String(describing: newStatus))"
            }
    }

    override func launch() {
        guard timer == nil else { return }
        status = .requestedStart
        displayedOutput += "\n"

        if maxTimesFired == 0 {
            return terminate(because: "started with maxTimesFired: 0")
        }

        timer = Timer.scheduledTimer(withTimeInterval: timeInterval, repeats: true) { timer in
            if self.maxTimesFired > 0 {
                if self.currentTimesFired >= self.maxTimesFired {
                    return self.terminate(because: "exceeded max timer incidents")
                }
            }

            if self.status == .requestedStop {
                return self.terminate(because: "finally detected stop request")
            }

            self.displayedOutput += "\(Date.now): timer firing, #\(self.currentTimesFired)\n"
            self.currentTimesFired += 1
            self.status = .startedWithOutput
        }

        status = .startedNoOutput
    }

    override func terminate() {
        return self.terminate(because: "impatient terminate request")
    }

    private func terminate(because reason: String?) {
        if reason != nil {
            self.displayedOutput += "\(Date.now): terminating because \(reason!)"
        }

        timer?.invalidate()
        timer = nil

        status = .stopped
    }
}
