import Alamofire
import Combine
import SwiftUI

class SimplePing: Job {
    let pingEndpoint: String
    let timeInterval: TimeInterval

    var timer: Timer? = nil

    init(
            _ label: String,
            _ pingEndpoint: String,
            timeInterval: TimeInterval = 5
    ) {
        self.pingEndpoint = pingEndpoint
        self.timeInterval = timeInterval

        super.init()

        sidebarTitle = label
        ribbonText = "\(label)\n\(pingEndpoint)"

        displayedOutput = ""
    }

    override func launch() -> SimplePing {
        guard timer == nil else {
            self.displayedOutput += "\(Date.now): requested SimplePing.launch(), but was already running"
            return self
        }
        status = .requestedStart
        displayedOutput += "\n"

        timer = Timer.scheduledTimer(withTimeInterval: timeInterval, repeats: true) { timer in
            if self.status == .requestedStop {
                _ = self.terminate(because: "finally detected stop request")
            }

            AF.request(
                self.pingEndpoint,
                method: .head
            )
            .response { r in
                switch r.result {
                case .success(let data):
                    if self.status == .stopped {
                        self.displayedOutput += "\(Date.now): timer fired after .stopped detected, exiting\n"
                        return
                    }

                    self.status = .startedWithOutput
                    self.displayedOutput += "\(Date.now): HEAD success"
                    if data != nil {
                        if let dataAsString = String(data: data!, encoding: .utf8) {
                            self.displayedOutput += ", \(dataAsString)"
                        }
                    }
                    self.displayedOutput += "\n"

                case .failure(let error):
                    self.status = .requestedStart
                    self.displayedOutput += "\(Date.now): \(error.localizedDescription)\n"
                    print("HEAD \(self.pingEndpoint) => " + error.localizedDescription)
                }
            }
        }

        timer!.fire()

        return self
    }

    override func terminate() -> SimplePing {
        return self.terminate(because: "impatient terminate request")
    }

    private func terminate(because reason: String?) -> SimplePing {
        timer?.invalidate()
        timer = nil

        if reason != nil {
            self.displayedOutput += "\(Date.now): terminating because \(reason!)\n"
        }

        status = .stopped
        return self
    }
}
