import Combine
import Foundation
import SwiftUI


class JobsManagerService: Observable, ObservableObject {
    @Published var renderableJobs: [Job]

    init() {
        renderableJobs = [
            TimeJob("quick timer", timeInterval: 0.2, maxTimesFired: 48),
            TimeJob("infinite", maxTimesFired: -1),
            SimpleProcess("/bin/date"),
            SimpleProcess("/sbin/ifconfig"),
            SimpleProcess("/usr/bin/man", ["man"]),
            SimpleProcess("/usr/bin/pmset", ["-g", "rawlog"]),
        ]
    }
}
