import Foundation
import SwiftUI

@main
struct BrokegenApp: App {
    private var proxyProcess: ProxyProcess
    @State private var proxyOutput: String

    init() {
        self.proxyProcess = ProxyProcess(["/usr/sbin/ioreg", "-c", "IOPlatformExpertDevice", "-d", "2"])
        self._proxyOutput = State(initialValue: "[waiting for process to start]")
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                headerText: "ioreg -c IOPlatformExpertDevice",
                text: $proxyOutput)
            .task {
                proxyProcess.launch { result, stdoutData in
                    self.proxyOutput = String(data: stdoutData, encoding: .utf8)!
                }
            }
        }
    }
}
