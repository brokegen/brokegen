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

    @Published public var status: JobStatus
    @Published public var sidebarTitle: String

    @Published public var ribbonText: String

    /// Additional text describing Job status, intended to be the header area of a View.
    /// Should describe broad context, like whether the job is running, when it was last updated, etc.
    @Published public var displayedStatus: String
    @Published public var displayedOutput: String

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

    @Published var showRelativeTimes: Bool = false
    var relativeTimesUpdater: AnyCancellable? = nil
    var relativeTimesUpdaterTimer: Timer? = nil

    override init() {
        super.init()

        displayedStatusUpdater = self.$status
            .sink { newStatus in
                if let (_, prevStatus) = self.historicalStatusUpdates.last {
                    if prevStatus == newStatus {
                        return
                    }
                }

                switch newStatus {
                case .requestedStart, .startedNoOutput, .startedWithOutput, .requestedStop:
                    self.showRelativeTimes = true
                case _:
                    self.showRelativeTimes = false
                }

                self.historicalStatusUpdates.append((Date.now, newStatus))
                self.updateDisplayedStatusTexts()
            }
        self.status = .notStarted

        displayedOutput = ""

        relativeTimesUpdater = self.$showRelativeTimes
            .sink { showRelativeTimes in
                if !showRelativeTimes {
                    self.relativeTimesUpdaterTimer?.invalidate()
                    self.relativeTimesUpdaterTimer = nil
                }
                else if self.relativeTimesUpdaterTimer == nil {
                    self.relativeTimesUpdaterTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                        self.updateDisplayedStatusTexts()
                    }
                }
            }
    }

    func updateDisplayedStatusTexts(forceRelativeTimes: Bool = false) {
        if showRelativeTimes || forceRelativeTimes {
            var stringMaker = ""
            let referenceTime = Date.now

            if self.historicalStatusUpdates.count > 1 {
                for (time, status) in self.historicalStatusUpdates {
                    let elapsedTime = String(format: "%.3f seconds ago", referenceTime.timeIntervalSince(time))
                    stringMaker += "\(elapsedTime): status updated to \(status)\n"
                }
                stringMaker += "\n\n"
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
