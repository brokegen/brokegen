import Combine
import Foundation
import SwiftUI


class JobsManagerService: Observable, ObservableObject {
    @Published var renderableJobs: [Job]

    init() {
        renderableJobs = [
            // Use prime numbers for these, because we can
            SimplePing("ping ollama", "http://localhost:11434", timeInterval: 13).launch(),
            SimplePing("ping rag-proxy", "http://localhost:6635", timeInterval: 17).launch(),
            SimplePing("ping brokegen-server", "http://localhost:6635", timeInterval: 5).launch(),
            SimplePing("ping brokegen-server:norag", "http://localhost:6636", timeInterval: 7).launch(),
            SimplePing("ping brokegen-server+rag", "http://localhost:6637", timeInterval: 11).launch(),
            TimeJob("infinitimer", maxTimesFired: -1).launch(),
            StayAwakeService(),
            TimeJob("quick timer", timeInterval: 0.2, maxTimesFired: 48),
            SimplePing("ping ollama-proxy", "http://localhost:6633", timeInterval: 19),
            SimpleProcess("/usr/bin/pmset", ["-g", "rawlog"]),
            SimpleProcess("/sbin/ifconfig"),
            SimpleProcess("/bin/date"),
            SimpleProcess("/usr/bin/man", ["man"]),
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

        let ollamaProxy = SimpleProcess(
            Bundle.main.url(forResource: "brokegen-ollama-proxy", withExtension: nil)!,
            [
                "--data-dir",
                directoryPath.path(percentEncoded: false),
            ]
        )
        renderableJobs.insert(ollamaProxy, at: 8)

        let serverNoRag = SimpleProcess(
            Bundle.main.url(forResource: "brokegen-server", withExtension: nil)!,
            [
                "--data-dir",
                directoryPath.path(percentEncoded: false),
                "--enable-rag=false",
                "--bind-port=6636",
            ]
        )
        renderableJobs.insert(serverNoRag, at: 5)

        let server = RestartableProcess(
            Bundle.main.url(forResource: "brokegen-server", withExtension: nil)!,
            [
                "--data-dir",
                directoryPath.path(percentEncoded: false),
                "--enable-rag=true",
                "--bind-port=6637",
            ]
        )
        renderableJobs.insert(server, at: 6)
    }
}