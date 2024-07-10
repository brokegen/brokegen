import Combine
import Foundation
import SwiftUI

/// This is very simple code for launching an external process, with virtually no testing or validation.
/// Which means that in error conditions, we're very likely to leave handles and memory leaks everywhere.
class OneShotProcess: Job {
    var task: Process?

    convenience init(_ pathAndArguments: [String]) {
        // TODO: Decide what to actually do in impossible cases
        if pathAndArguments.isEmpty {
            self.init("/usr/bin/false", ["no arguments provided"])
        }
        else {
            self.init(pathAndArguments.first!, Array(pathAndArguments.dropFirst()))
        }
    }

    convenience init(_ launchPath: String, _ arguments: [String] = []) {
        self.init(URL(fileURLWithPath: launchPath), arguments)
    }

    init(_ launchURL: URL, _ arguments: [String] = []) {
        task = Process()
        task!.executableURL = launchURL
        task!.arguments = arguments

        super.init()

        sidebarTitle = launchURL.lastPathComponent
        ribbonText = "\(launchURL.path(percentEncoded: false))"
        if arguments.count > 0 {
            ribbonText += "\n\(arguments)"
        }
    }

    override func launch() -> OneShotProcess {
        status = .requestedStart
        guard task != nil else {
            status = .error("task already started once")
            return self
        }

        task!.terminationHandler = { _ in
            DispatchQueue.main.sync {
                self.task = nil
                self.status = .stopped
            }
        }

        let pipe = Pipe()
        task!.standardOutput = pipe
        task!.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard data.count > 0 else { return }

            let dataAsString = String(data: data, encoding: .utf8)
            guard dataAsString != nil else { return }
            guard dataAsString!.count > 0 else { return }

            // TODO: Should this be .sync?
            DispatchQueue.main.async {
                self.displayedOutput += dataAsString!
                self.status = .startedWithOutput
            }
        }

        do {
            try task!.run()
            status = .startedNoOutput
        }
        catch {
            status = .error("failed to start task")
        }

        return self
    }

    override func terminate() -> OneShotProcess {
        task?.terminate()
        task = nil

        status = .stopped
        return self
    }

    override func terminatePatiently() -> OneShotProcess {
        guard task != nil else {
            status = .stopped
            return self
        }

        status = .requestedStop

        Task {
            await withCheckedContinuation { continuation in
                task?.waitUntilExit()
                task = nil

                DispatchQueue.main.sync {
                    self.status = .stopped
                }
                continuation.resume()
            }
        }

        return self
    }
}

#Preview {
    JobOutputView(job: OneShotProcess(
        "/usr/sbin/ioreg",
        ["-c", "IOPlatformExpertDevice", "-d", "2"])
    )
        .fixedSize()
        .frame(minHeight: 400)
}
