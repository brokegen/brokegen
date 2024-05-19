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

protocol JobProtocol {
    var sidebarTitle: String { get }

//    var ribbonText: String { get }
//
//    var displayedStatus: String { get }
////    var displayedOutput: String { get }
//
//    func displayedOutput() -> String
}

class Job: ObservableObject, Identifiable {
    let id: UUID = UUID()

    @Published var status: JobStatus
    @Published var displayedOutput: String

    init() {
        status = .notStarted
        displayedOutput = "[base Job, not initialized]\n"
    }

    func launch() {
        status = .error
        displayedOutput += "[base Job launched, but this should be overridden]\n"
    }
}

class TimeJob: Job {
    let timeInterval: TimeInterval
    let maxTimesFired: Int
    var currentTimesFired: Int = 0

    var timer: Timer? = nil

    init(_ timeInterval: TimeInterval = 5, maxTimesFired: Int = 24) {
        self.timeInterval = timeInterval
        self.maxTimesFired = maxTimesFired

        super.init()
        self.displayedOutput = ""
    }

    override func launch() {
        status = .requestedStart
        guard timer == nil else { return }

        if maxTimesFired == 0 {
            displayedOutput += "\(Date.now): TimeJob started with maxTimesFired: 0, exiting"
            status = .stopped
            return
        }

        timer = Timer.scheduledTimer(withTimeInterval: timeInterval, repeats: true) { timer in
            if self.maxTimesFired > 0 {
                if self.currentTimesFired > self.maxTimesFired {
                    timer.invalidate()
                    self.timer = nil

                    self.displayedOutput += "\(Date.now): ended timer after \(self.currentTimesFired)"
                    self.status = .stopped
                    return
                }
            }

            self.displayedOutput += "\(Date.now): timer firing, #\(self.currentTimesFired)\n"
            self.currentTimesFired += 1
            self.status = .startedWithOutput
        }

        status = .startedNoOutput
    }

    func terminate() {
        status = .requestedStop

        timer?.invalidate()
        timer = nil

        status = .stopped
    }

    func terminatePatiently() {
        status = .requestedStop
    }
}

//class BaseJob: ObservableObject, Identifiable {
//    var id: UUID = UUID()
//
//    func makeTitle() -> String {
//        return "BaseJob id=\(id)"
//    }
//
//    @Published var status: JobStatus
//
//    func sidebarTitle() -> String
//    func ribbonText() -> String
//
//    func launch() {}
//}


class TextShowingJob {
    init(_ arg0: URL, arguments: [String]) {
    }

    func makeTitle() -> String {
        return "Job #\(self), pid=-1"
    }

    func launch() {
        // Start a background task to change status + dump some text sometimes
    }
}
