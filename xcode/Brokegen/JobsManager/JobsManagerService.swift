import Combine
import Foundation
import SwiftUI


class JobsManagerService: Observable, ObservableObject {
    @Published var renderableJobs: [Job]

    init() {
        let infinitimer = TimeJob("infinitimer", maxTimesFired: -1)
        infinitimer.launch()

        renderableJobs = [
            infinitimer,
            TimeJob("quick timer", timeInterval: 0.2, maxTimesFired: 48),
            SimpleProcess("/usr/bin/pmset", ["-g", "rawlog"]),
            SimpleProcess("/sbin/ifconfig"),
            SimpleProcess("/bin/date"),
            SimpleProcess("/usr/bin/man", ["man"]),
            StayAwakeService(),
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
        renderableJobs.insert(ollamaProxy, at: 0)

        let serverNoRag = SimpleProcess(
            Bundle.main.url(forResource: "brokegen-server", withExtension: nil)!,
            [
                "--data-dir",
                directoryPath.path(percentEncoded: false),
                "--enable-rag=false",
                "--bind-port=6636",
            ]
        )
        renderableJobs.insert(serverNoRag, at: 1)

        let server = RestartableProcess(
            Bundle.main.url(forResource: "brokegen-server", withExtension: nil)!,
            [
                "--data-dir",
                directoryPath.path(percentEncoded: false),
                "--enable-rag=true",
                "--bind-port=6637",
            ]
        )
        renderableJobs.insert(server, at: 2)
    }
}
