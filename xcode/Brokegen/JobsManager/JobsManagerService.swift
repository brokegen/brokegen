import Combine
import Foundation
import SwiftUI


class JobsManagerService: Observable, ObservableObject {
    @Published var renderableJobs: [Job]
    @Published var specialJobs: [Job]

    init(startPingsImmediately: Bool = false) {
        renderableJobs = [
            // Use prime numbers for these, because we can
            SimplePing("ping ollama", "http://localhost:11434", timeInterval: 13),
            SimplePing("ping rag-proxy", "http://localhost:6635", timeInterval: 17),
            SimplePing("ping brokegen-server", "http://localhost:6635", timeInterval: 5),
            SimplePing("ping brokegen-server:norag", "http://localhost:6636", timeInterval: 7),
            SimplePing("ping brokegen-server+rag", "http://localhost:6637", timeInterval: 11),
            TimeJob("infinitimer", maxTimesFired: -1).launch(),
            StayAwakeService(),
            TimeJob("quick timer", timeInterval: 0.2, maxTimesFired: 48),
            SimplePing("ping ollama-proxy", "http://localhost:6633", timeInterval: 19),
            SimpleProcess("/usr/bin/pmset", ["-g", "rawlog"]),
            SimpleProcess("/sbin/ifconfig"),
            SimpleProcess("/bin/date"),
            SimpleProcess("/usr/bin/man", ["man"]),
        ]

        specialJobs = []

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

        let ollamaProxy = SimpleProcess(
            Bundle.main.url(forResource: "brokegen-ollama-proxy", withExtension: nil)!,
            [
                "--data-dir",
                directoryPath.path(percentEncoded: false),
                "--log-level=debug",
            ]
        )
        renderableJobs.insert(ollamaProxy, at: 8)

        let server = RestartableProcess(
            Bundle.main.url(forResource: "brokegen-server", withExtension: nil)!,
            [
                "--data-dir",
                directoryPath.path(percentEncoded: false),
                "--log-level=debug",
            ]
        )
        specialJobs.append(server)

        if startPingsImmediately {
            for job in renderableJobs {
                if job is SimplePing {
                    _ = job.launch()
                }
            }
        }
    }
}
