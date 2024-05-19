import Combine
import Foundation
import SwiftUI

class SimpleJob: ObservableObject, Identifiable {
    var id: UUID = UUID()

    let executableURL: URL
    let arguments: [String]

    let process: ManagedProcess
    @Published var entireCapturedOutput: String = "[not initialized]"
    var processDone: Date? = nil

    init(_ arg0: URL, arguments: [String]) {
        self.executableURL = arg0
        self.arguments = arguments

        self.process = ManagedProcess(executableURL, argv: arguments)
        self.entireCapturedOutput = "[init called]"
    }

    func makeTitle() -> String {
        var title = executableURL.path()
        if self.arguments.count > 0 {
            title = "\(title)\n\(self.arguments)"
        }
        if self.processDone != nil {
            title = "\(title)\nterminated at \(self.processDone!)"
        }

        return title
    }

    func launch() {
        self.entireCapturedOutput = "[launch called at \(Date.now)]"

        return process.launch { result, stdoutData in
            print("[DEBUG] process completed: \(self.makeTitle())")
            self.entireCapturedOutput = String(data: stdoutData, encoding: .utf8)!
            self.processDone = Date.now
        }
    }
}

class JobsManagerService: Observable, ObservableObject {
    @Published var renderableJobs: [Job]

    // Deprecated
    var knownJobs: [SimpleJob] = []

    init() {
        renderableJobs = [
            TimeJob("quick timer", timeInterval: 0.5, maxTimesFired: 6),
            TimeJob("infinite", maxTimesFired: -1),
        ]

//
//        _ = addProcess(["/bin/date"])
//        _ = addProcess(["/sbin/ifconfig"])
//        _ = addProcess(["/usr/bin/man", "man"])

//        let task = Process()
//        task.launchPath = "/usr/bin/pmset"
//        task.arguments = ["-g", "rawlog"]
//
//        let pipe = Pipe()
//        task.standardOutput = pipe
//
//        pipe.fileHandleForReading.readabilityHandler = { handle in
//            let data = handle.availableData
//            if data.count > 0 {
//                print(String(data: data, encoding: .utf8) ?? "[invalid data]")
//            }
//        }
//
//        do {
//            try task.run()
//        }
//        catch {}
//        task.waitUntilExit()
//        task.terminate()
    }

    func addProcess(_ argv: [String]) -> SimpleJob {
        let job = SimpleJob(
            URL(fileURLWithPath: argv[0]),
            arguments: Array(argv.dropFirst()))
        knownJobs.append(job)

        return job
    }
}
