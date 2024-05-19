import SwiftUI

struct JobOutputView: View {
    @ObservedObject var job: Job

    var body: some View {
        ScrollViewReader { scrollViewProxy in
            RibbonView(String(describing: job.status))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)

            List {
                Text(String(describing: job.status))
                    .monospaced()
                    .font(.title2)

                Divider()

                Text(job.displayedOutput)
                    .monospaced()
                    .font(.title2)
            }

            Spacer()
        }
    }
}

#Preview {
    JobOutputView(job: TimeJob("Xcode preview"))
    .fixedSize()
    .frame(minHeight: 400)
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
