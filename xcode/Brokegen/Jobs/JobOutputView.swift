import SwiftUI
import SwiftTerm
import AppKit

struct JobOutputView: View {
    @ObservedObject var job: Job

    var body: some View {
        ScrollViewReader { scrollViewProxy in
            RibbonView(job.ribbonText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)

            List {
                Text(job.displayedStatus)
                    .monospaced()
                    .font(.title2)

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
