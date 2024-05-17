import SwiftUI

struct ProcessOutputView: View {
    // TODO: This seems bad, but, what should we do instead?
    @StateObject var job: SimpleJob

    init(_ job: SimpleJob) {
        _job = StateObject(wrappedValue: job)
        self.job.launch()
    }

    var body: some View {
        VStack(alignment: .leading) {
            BigToolbar(job.makeTitle())

            Text(job.makeTitle())
                .monospaced()
                .font(.title2)

            Text(job.entireCapturedOutput)
                .monospaced()
                .font(.title2)

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ProcessOutputView(SimpleJob(
        URL(fileURLWithPath: "invalid, all invalid, don't write this"),
        arguments: []
    ))
    .fixedSize()
    .frame(height: 1200)
}

#Preview {
    let job = SimpleJob(
        URL(fileURLWithPath: "/usr/sbin/ioreg"),
        arguments: ["-c", "IOPlatformExpertDevice", "-d", "2"])

    @State var sampleArgv = "/usr/sbin/ioreg -c IOPlatformExpertDevice -d 2"
    @State var sampleText = """
    +-o Root  <class IORegistryEntry, id 0x100000100, retain 38>
    +-o J316cAP  <class IOPlatformExpertDevice, id 0x100000275, registered, matched, active, busy 0 (659599 ms), retain 41>
      {
        "manufacturer" = <"Apple Inc.">
        "compatible" = <"J316cAP","MacBookPro18,2","AppleARM">
        "model" = <"MacBookPro18,2">
      }
    """

    let jobBinding = State(wrappedValue: job)

    struct ViewHolder: View {
        let job2 = SimpleJob(
            URL(fileURLWithPath: "/usr/sbin/ioreg"),
            arguments: ["-c", "IOPlatformExpertDevice", "-d", "2"])

        var body: some View {
            ProcessOutputView(job2)
        }
    }

    return ViewHolder()
}
