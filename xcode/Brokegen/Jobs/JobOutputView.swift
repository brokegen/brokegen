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
