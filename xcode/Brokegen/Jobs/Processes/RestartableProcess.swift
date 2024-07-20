import Combine
import Foundation
import SwiftUI

class RestartableProcess: Job {
    var processes: [Process] = []
    let executableURL: URL
    let arguments: [String]
    let environment: [String : String]

    init(_ launchURL: URL, _ arguments: [String] = [], environment: [String : String] = [:], sidebarTitle: String? = nil) {
        self.executableURL = launchURL
        self.arguments = arguments
        self.environment = environment

        super.init()

        self.sidebarTitle = sidebarTitle ?? launchURL.lastPathComponent
        ribbonText = "\(launchURL.path(percentEncoded: false))"
        if arguments.count > 0 {
            ribbonText += "\n\(arguments)"
        }
        if environment.count > 0 {
            ribbonText += "\n\(environment)"
        }
    }

    /// TODO: This causes 10% CPU for a short-running process, gotta figure out why.
    override func launch() -> Self {
        guard processes.isEmpty else {
            return self
        }

        status = .requestedStart

        let currentProcess = Process()
        currentProcess.executableURL = executableURL
        currentProcess.arguments = arguments

        currentProcess.terminationHandler = { _ in
            DispatchQueue.main.sync {
                if let index = self.processes.firstIndex(of: currentProcess) {
                    self.processes.remove(at: index)
                }
                self.status = .stopped
            }
        }

        let pipe = Pipe()
        currentProcess.standardOutput = pipe
        currentProcess.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard data.count > 0 else { return }

            let dataAsString = String(data: data, encoding: .utf8)
            guard dataAsString != nil else { return }
            guard dataAsString!.count > 0 else { return }

            DispatchQueue.main.async {
                if self.displayedOutput.count > 256_000 {
                    self.displayedOutput = String(self.displayedOutput.suffix(128_000))
                }

                self.displayedOutput += dataAsString!
                self.status = .startedWithOutput
            }
        }

        do {
            try currentProcess.run()
            processes.append(currentProcess)
            status = .startedNoOutput
        }
        catch {
            status = .error("failed to launch process")
        }

        return self
    }

    override func terminate() -> Self {
        for process in processes {
            process.terminate()
        }
        processes.removeAll()

        status = .stopped
        return self
    }

    override func terminatePatiently()  -> Self {
        guard !processes.isEmpty else {
            status = .stopped
            return self
        }

        status = .requestedStop

        Task {
            await withCheckedContinuation { continuation in
                for process in processes {
                    process.waitUntilExit()
                }
                processes.removeAll()

                DispatchQueue.main.sync {
                    self.status = .stopped
                }
                continuation.resume()
            }
        }

        return self
    }
}
