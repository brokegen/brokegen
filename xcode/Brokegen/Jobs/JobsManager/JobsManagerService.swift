import Combine
import Foundation
import SwiftUI


class JobsManagerService: Observable, ObservableObject {
    @Published var sidebarRenderableJobs: [Job] = []
    @Published var storedJobs: [Job] = []

    init() {}
}

class DefaultJobsManagerService: JobsManagerService {
    func createDataDir() -> String {
        let fileManager = FileManager.default
        let applicationSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleName = Bundle.main.bundleIdentifier!

        let directoryPath = applicationSupportDirectory.appendingPathComponent(bundleName)

        // We return true regardless of whether the data directory was created.
        // It's on the other app to deal with missing data/dirs.
        try? fileManager.createDirectory(at: directoryPath, withIntermediateDirectories: true, attributes: nil)

        return directoryPath.path(percentEncoded: false)
    }

    init(startServicesImmediately: Bool, allowExternalTraffic: Bool) {
        super.init()
        let dataDir = createDataDir()

        let server = ManagedService(
            Bundle.main.url(forResource: "brokegen-server", withExtension: nil)!,
            [
                "--data-dir",
                dataDir,
                "--log-level=debug",
                "--bind-host",
                allowExternalTraffic ? "0.0.0.0" : "127.0.0.1",
                "--bind-port",
                "6635",
                "--install-terminate-endpoint",
                "true",
            ],
            sidebarTitle: "brokegen-server\n(embedded x86 binary)",
            pingEndpoint: "http://localhost:6635",
            pingInterval: 23,
            terminateEndpoint: "http://localhost:6635/terminate"
        )
        if startServicesImmediately {
            _ = server.launch()
        }

        let ollama = ManagedService(
            Bundle.main.url(forResource: "ollama-darwin", withExtension: nil)!,
            ["serve"],
            environment: [
                "OLLAMA_HOST": "127.0.0.1:11434",
                "OLLAMA_NUM_PARALLEL": "3",
                "OLLAMA_MAX_LOADED_MODELS": "3",
                "OLLAMA_KEEP_ALIVE": "4h",
            ],
            sidebarTitle: "ollama v0.1.44\n(embedded binary)",
            pingEndpoint: "http://localhost:11434",
            pingInterval: 13
        )
        if startServicesImmediately {
            _ = ollama.launch()
        }

        let importantJobs = [
            server,
            ollama,
            StayAwakeService(),
        ]

        self.sidebarRenderableJobs = importantJobs
        self.storedJobs = importantJobs + [
            // Use prime numbers for these, because we can
            SimplePing("brokegen-server heartbeat", "http://localhost:6635", timeInterval: 23),
            SimplePing("ollama heartbeat", "http://localhost:11434", timeInterval: 13),
            StayAwakeService(),
            TimeJob("fast infinitimer", timeInterval: 0.1, maxTimesFired: -1),
            TimeJob("quick timer", timeInterval: 0.2, maxTimesFired: 48),
            OneShotProcess("/usr/bin/pmset", ["-g", "rawlog"]).launch(),
            OneShotProcess("/sbin/ifconfig"),
            OneShotProcess("/bin/date"),
            OneShotProcess("/usr/bin/man", ["man"]),
            TimeJob("infinitimer", maxTimesFired: -1).launch(),
        ]
    }
}
