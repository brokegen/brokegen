import Combine
import Foundation
import SwiftUI

class RestartableProcess: Job {
    var processes: [Process] = []
    let executableURL: URL
    let arguments: [String]

    init(_ launchURL: URL, _ arguments: [String] = []) {
        self.executableURL = launchURL
        self.arguments = arguments

        super.init()

        sidebarTitle = launchURL.lastPathComponent
        ribbonText = "\(launchURL.path(percentEncoded: false))"
        if arguments.count > 0 {
            ribbonText += "\n\(arguments)"
        }
    }

    override func launch() {
        guard processes.isEmpty else {
            return
        }

        status = .requestedStart

        let currentProcess = Process()
        currentProcess.executableURL = executableURL
        currentProcess.arguments = arguments

        currentProcess.terminationHandler = { _ in
            DispatchQueue.main.async {
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
    }

    override func terminate() {
        for process in processes {
            process.terminate()
        }
        processes.removeAll()

        status = .stopped
    }

    override func terminatePatiently() {
        guard !processes.isEmpty else {
            status = .stopped
            return
        }

        status = .requestedStop

        Task {
            await withCheckedContinuation { continuation in
                for process in processes {
                    process.waitUntilExit()
                }
                processes.removeAll()

                DispatchQueue.main.async {
                    self.status = .stopped
                }
                continuation.resume()
            }
        }
    }
}

#Preview {
    JobOutputView(job: SimpleProcess(
        "/usr/sbin/ioreg",
        ["-c", "IOPlatformExpertDevice", "-d", "2"])
    )
        .fixedSize()
        .frame(minHeight: 400)
}
