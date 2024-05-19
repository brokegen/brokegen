import Combine
import Foundation
import SwiftUI


class JobsManagerService: Observable, ObservableObject {
    @Published var renderableJobs: [Job]

    init() {
        renderableJobs = [
            TimeJob("infinite", maxTimesFired: -1),
            TimeJob("quick timer", timeInterval: 0.2, maxTimesFired: 48),
            SimpleProcess("/usr/bin/pmset", ["-g", "rawlog"]),
            SimpleProcess("/sbin/ifconfig"),
            SimpleProcess("/bin/date"),
            SimpleProcess("/usr/bin/man", ["man"]),
        ]

        // And now the annoying ones
        let dataDir = URL.applicationSupportDirectory.path(percentEncoded: false)
        let ollamaProxy = SimpleProcess(
            Bundle.main.url(forResource: "brokegen-ollama-proxy", withExtension: nil)!,
            [
                "--data-dir",
                dataDir,
            ]
        )

        // TODO: Where is the error handling for this?
        ollamaProxy.launch()
        renderableJobs.insert(ollamaProxy, at: 0)
    }
}
