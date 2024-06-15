import Combine
import Foundation
import SwiftUI


class JobsManagerService: Observable, ObservableObject {
    @Published var sidebarRenderableJobs: [Job] = []
    @Published var storedJobs: [Job] = []

    init() {}
}

class DefaultJobsManagerService: JobsManagerService {
    init(startPingsImmediately: Bool = false) {
        super.init()

        let importantJobs = [
            // Use prime numbers for these, because we can
            SimplePing("brokegen-server heartbeat", "http://localhost:6635", timeInterval: 23),
            SimplePing("ollama heartbeat", "http://localhost:11434", timeInterval: 13),
            StayAwakeService(),
            TimeJob("fast infinitimer", timeInterval: 0.1, maxTimesFired: -1),
        ]

        self.sidebarRenderableJobs = importantJobs
        self.storedJobs = importantJobs + [
            TimeJob("quick timer", timeInterval: 0.2, maxTimesFired: 48),
            SimpleProcess("/usr/bin/pmset", ["-g", "rawlog"]).launch(),
            SimpleProcess("/sbin/ifconfig"),
            SimpleProcess("/bin/date"),
            SimpleProcess("/usr/bin/man", ["man"]),
            TimeJob("infinitimer", maxTimesFired: -1).launch(),
        ]

        let fileManager = FileManager.default
        let applicationSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleName = Bundle.main.bundleIdentifier!

        let directoryPath = applicationSupportDirectory.appendingPathComponent(bundleName)

        do {
            // Create the directory if it doesn't exist
            try fileManager.createDirectory(at: directoryPath, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("Error creating data directory: \(directoryPath)")
            return
        }

        let ollama = RestartableProcess(
            Bundle.main.url(forResource: "ollama-darwin", withExtension: nil)!,
            ["serve"],
            environment: [
                "OLLAMA_NUM_PARALLEL": "3",
                "OLLAMA_MAX_LOADED_MODELS": "3",
                "OLLAMA_KEEP_ALIVE": "4h",
            ],
            sidebarTitle: "ollama v0.1.44\n(embedded binary)"
        )
        self.sidebarRenderableJobs.insert(ollama, at: 0)
        self.storedJobs.insert(ollama, at: 0)

        let server = RestartableProcess(
            Bundle.main.url(forResource: "brokegen-server", withExtension: nil)!,
            [
                "--data-dir",
                directoryPath.path(percentEncoded: false),
                "--log-level=debug",
            ],
            sidebarTitle: "brokegen-server\n(embedded x86 binary)"
        )
        self.sidebarRenderableJobs.insert(server, at: 0)
        self.storedJobs.insert(server, at: 0)

        if startPingsImmediately {
            for job in storedJobs {
                if job is SimplePing {
                    _ = job.launch()
                }
            }
        }
    }
}
