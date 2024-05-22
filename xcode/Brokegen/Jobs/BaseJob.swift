import Combine
import SwiftUI

enum JobStatus: Equatable {
    case notStarted
    case requestedStart
    case startedNoOutput
    case startedWithOutput
    case requestedStop
    case stopped
    case error(_ reason: String)
}

class BaseJob: ObservableObject, Identifiable {
    let id: UUID = UUID()

    @Published var status: JobStatus
    @Published var sidebarTitle: String

    @Published var ribbonText: String

    /// Additional text describing Job status, intended to be the header area of a View.
    /// Should describe broad context, like whether the job is running, when it was last updated, etc.
    @Published var displayedStatus: String
    @Published var displayedOutput: String

    init() {
        status = .notStarted
        sidebarTitle = "[sidebarTitle]"
        ribbonText = "[ribbonText]"
        displayedStatus = "[displayedStatus]"
        displayedOutput = "[BaseJob not initialized]\n"
    }

    func launch() -> BaseJob {
        status = .error("BaseJob.launch() not implemented")
        displayedOutput += "[BaseJob launched, but this should have been overridden]\n"
        return self
    }

    func terminate() -> BaseJob {
        status = .stopped
        return self
    }

    func terminatePatiently() -> BaseJob {
        status = .requestedStop
        return self
    }
}

/// The important part is this Job is more verbose and prints more human-readable words
class Job: BaseJob {
    var displayedStatusUpdater: AnyCancellable? = nil
    var historicalStatusUpdates: [(Date, JobStatus)] = []

    override init() {
        super.init()

        displayedStatusUpdater = self.$status
            .sink { newStatus in
                if let (_, prevStatus) = self.historicalStatusUpdates.last {
                    if prevStatus == newStatus {
                        return
                    }
                }

                self.historicalStatusUpdates.append((Date.now, newStatus))
                self.updateDisplayedStatusTexts()
            }
        self.status = .notStarted

        displayedOutput = ""
    }

    func status(_ status: JobStatus) -> Job {
        self.status = status
        return self
    }

    func updateDisplayedStatusTexts(useRelativeTimes: Bool = true) {
        if useRelativeTimes {
            var stringMaker = ""
            let referenceTime = Date.now

            if self.historicalStatusUpdates.count > 1 {
                for (time, status) in self.historicalStatusUpdates.dropLast() {
                    let elapsedTime = String(format: "%.3f seconds ago", referenceTime.timeIntervalSince(time))
                    stringMaker += "\(elapsedTime): status updated to \(status)\n"
                }
                stringMaker += "\n\n"
            }

            if let (lastTime, lastStatus) = self.historicalStatusUpdates.last {
                stringMaker += "Last update \(lastTime): status set to \(lastStatus)"
            }

            self.displayedStatus = stringMaker
        }
        else {
            self.displayedStatus =
                self.historicalStatusUpdates.map {
                    "\($0.0): status updated to \($0.1)"
                }
                .joined(separator: "\n")
        }
    }
}
