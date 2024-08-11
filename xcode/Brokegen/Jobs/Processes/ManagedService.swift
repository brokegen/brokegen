import Alamofire
import Combine
import Foundation
import SwiftUI

/// Represents the equivalent of a service/daemon:
///
/// 1. Check if the target process is available via an HTTP "ping"
/// 2. (optional) If not, start the process as a child of ourselves
/// 3. (optional) Send a termination request when we're about to exit
///
class ManagedService: Job {
    var processes: [Process] = []
    let executableURL: URL
    let arguments: [String]
    let environment: [String : String]

    let pingEndpoint: String?
    let pingInterval: TimeInterval
    /// Specific to our server: call /terminate when we want it to exit
    let terminateEndpoint: String?

    var timer: Timer? = nil

    init(
        _ launchURL: URL,
        _ arguments: [String] = [],
        environment: [String : String] = [:],
        sidebarTitle: String? = nil,
        pingEndpoint: String?,
        pingInterval: TimeInterval = 2,
        terminateEndpoint: String? = nil
    ) {
        self.executableURL = launchURL
        self.arguments = arguments
        self.environment = environment
        self.pingEndpoint = pingEndpoint
        self.pingInterval = pingInterval
        self.terminateEndpoint = terminateEndpoint

        super.init()

        self.sidebarTitle = sidebarTitle ?? launchURL.lastPathComponent
        ribbonText = "\(launchURL.path(percentEncoded: false))"
        if arguments.count > 0 {
            ribbonText += "\n\(arguments)"
        }
        if environment.count > 0 {
            ribbonText += "\n\(environment)"
        }

        if pingEndpoint != nil {
            self.displayedOutput += "Configuration: ping \(pingEndpoint!) every \(pingInterval) seconds, launch service if not reachable\n"
            self.displayedOutput += "---\n"
        }
    }

    func doLaunch() {
        let currentProcess = Process()
        currentProcess.executableURL = executableURL
        currentProcess.arguments = arguments

        var mergedEnvironment = ProcessInfo().environment
        mergedEnvironment.merge(environment) { $1 }
        currentProcess.environment = mergedEnvironment

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
                // Truncate the output to 64k characters, because we rarely care about history.
                if self.displayedOutput.count > 64_000 {
                    self.displayedOutput = String(self.displayedOutput.suffix(32_000))
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
            status = .error("ManagedService failed to launch process")
        }
    }

    @Sendable
    func heartbeat(timer: Timer) -> Void {
        guard self.pingEndpoint != nil else { return }
        switch(status) {
        case .requestedStop, .stopped, .error(_):
            // Stop heartbeating if we're trying to stop
            return
        default:
            break
        }

        var responseStatusCode: Int? = nil

        AF.request(
            self.pingEndpoint!,
            method: .head
        )
        .onHTTPResponse { response in
            responseStatusCode = response.statusCode
        }
        .response { r in
            switch r.result {
            case .success(let data):
                if responseStatusCode != nil && !(200..<400).contains(responseStatusCode!) {
                    self.displayedOutput += "\(Date.now): HEAD \(self.pingEndpoint!) returned \(responseStatusCode!), assuming failure\n"
                    self.status = .error("HTTP \(responseStatusCode!)")
                }
                else {
                    self.displayedOutput += "\(Date.now): HEAD \(self.pingEndpoint!) success (ManagedService already running)"
                    if data != nil {
                        if let dataAsString = String(data: data!, encoding: .utf8) {
                            self.displayedOutput += ", \(dataAsString)"
                        }
                    }
                    self.displayedOutput += "\n"
                    self.status = .startedWithOutput
                }

            case .failure(_):
                // Try to launch the service.
                self.doLaunch()
            }
        }
    }

    override func launch() -> Self {
        guard processes.isEmpty else {
            self.displayedOutput += "\(Date.now): requested ManagedService.launch(), but was already running\n"
            return self
        }

        status = .requestedStart
        displayedOutput += "\n"

        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: pingInterval, repeats: true, block: self.heartbeat)
        }

        timer!.fire()

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
        timer?.invalidate()
        timer = nil

        status = .requestedStop

        if self.terminateEndpoint != nil {
            var responseStatusCode: Int? = nil

            AF.request(
                self.terminateEndpoint!,
                method: .put
            )
            .onHTTPResponse { response in
                responseStatusCode = response.statusCode
            }
            .response { r in
                switch r.result {
                case .success(let data):
                    if responseStatusCode != nil && !(200..<400).contains(responseStatusCode!) {
                        self.displayedOutput += "\(Date.now): PUT \(self.terminateEndpoint!) returned \(responseStatusCode!), assuming couldn't terminate\n"
                    }
                    else {
                        self.displayedOutput += "\(Date.now): PUT \(self.terminateEndpoint!) success (expecting exit)"
                        if data != nil {
                            if let dataAsString = String(data: data!, encoding: .utf8) {
                                self.displayedOutput += ", \(dataAsString)"
                            }
                        }
                        self.displayedOutput += "\n"
                        self.status = .stopped
                    }

                case .failure(_):
                    self.displayedOutput += "\(Date.now): PUT \(self.terminateEndpoint!) failed, assuming terminated\n"
                    self.status = .stopped
                }
            }
        }
        else {
            Task.detached {
                for process in self.processes {
                    process.waitUntilExit()
                }
                self.processes.removeAll()

                DispatchQueue.main.sync {
                    self.status = .stopped
                }
            }
        }

        return self
    }
}
