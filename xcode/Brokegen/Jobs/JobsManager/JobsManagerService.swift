import Combine
import Foundation
import SwiftUI


class JobsManagerService: Observable, ObservableObject {
    @Published var sidebarRenderableJobs: [Job] = []
    @Published var storedJobs: [Job] = []

    func terminateAll() -> Void {
        for job in storedJobs {
            _ = job.terminatePatiently()
        }

        for job in storedJobs {
            _ = job.terminate()
        }
    }
}

class DefaultJobsManagerService: JobsManagerService {
    func createDataDir() -> String {
        let directoryPath = URL.applicationSupportDirectory
        // We manually append the path component because unsigned apps get special problems
            .appendingPathComponent(Bundle.main.bundleIdentifier!)

        // We continue regardless of whether the data directory was created;
        // it's on the other apps to deal with missing data/dirs.
        try? FileManager.default.createDirectory(
            at: directoryPath,
            withIntermediateDirectories: true,
            attributes: nil)

        return directoryPath.path(percentEncoded: false)
    }

    init(startServicesImmediately: Bool, allowExternalTraffic: Bool) {
        super.init()
        let dataDir = createDataDir()

        var importantJobs: [Job] = []

        if let serverUrl = Bundle.main.url(forResource: "brokegen-server", withExtension: nil) {
            let server = ManagedService(
                serverUrl,
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
            importantJobs.append(server)
        }

        let ollamaUrl = Bundle.main.url(forResource: "ollama-darwin", withExtension: nil)
        if ollamaUrl != nil {
            let ollama = ManagedService(
                ollamaUrl!,
                ["serve"],
                environment: [
                    "OLLAMA_HOST": "127.0.0.1:11434",
                    "OLLAMA_NUM_PARALLEL": "3",
                    "OLLAMA_MAX_LOADED_MODELS": "3",
                    "OLLAMA_KEEP_ALIVE": "168h",
                    "OLLAMA_DEBUG": "1",
                ],
                sidebarTitle: "ollama v0.5.2\n(embedded binary)",
                pingEndpoint: "http://localhost:11434",
                pingInterval: 13
            )
            if startServicesImmediately {
                _ = ollama.launch()
            }
            importantJobs.append(ollama)
        }

        importantJobs.append(StayAwakeService())

        self.sidebarRenderableJobs = importantJobs
        self.storedJobs = importantJobs + [
            // Use prime numbers for these, because we can
            SimplePing("brokegen-server heartbeat", "http://localhost:6635", timeInterval: 23),
            SimplePing("ollama heartbeat", "http://localhost:11434", timeInterval: 13),
            StayAwakeService(),
            TimeJob("fast infinitimer", timeInterval: 0.1, maxTimesFired: -1),
            TimeJob("quick timer", timeInterval: 0.2, maxTimesFired: 48),
            OneShotProcess("/usr/bin/pmset", ["-g", "rawlog"]),
            OneShotProcess("/sbin/ifconfig"),
            RestartableProcess(URL(fileURLWithPath: "/bin/date")),
            OneShotProcess("/usr/bin/man", ["man"]),
            TimeJob("infinitimer", maxTimesFired: -1),
        ]

        if ollamaUrl != nil {
            self.storedJobs.append(
                RestartableProcess(
                    Bundle.main.url(forResource: "ollama-darwin", withExtension: nil)!,
                    ["ps"],
                    environment: [
                        "OLLAMA_DEBUG": "1",
                    ],
                    sidebarTitle: "ollama ps"
                )
            )
        }
    }
}
