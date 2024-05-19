import SwiftUI

struct JobsManagerSidebarView: View {
    @StateObject var service = JobsManagerService()

    var body: some View {
        Section(header: Text("Jobs")
            .font(.title2)
            .foregroundStyle(.primary)
            .padding(6)
        ) {
//            ForEach(managedProcessService.knownJobs) { job in
//                NavigationLink(destination: JobOutputView(job)) {
//                    HStack {
//                        Text(job.makeTitle())
//                            .font(.title2)
//                            .monospaced()
//
//                        Spacer()
//                        ProgressView().progressViewStyle(.linear)
//                    }
//                }
//            }

            ForEach(service.renderableJobs) { job in
                NavigationLink(destination: JobOutputView(job: job)) {
                    HStack {
                        Text(String(describing: job.status))
                            .font(.title2)
                            .monospaced()
                    }
                }
            }
        }
    }
}

#Preview {
    NavigationLink(destination: Text("fake dest")) {
        HStack {
            Text("X2")
                .font(.title2)
                .monospaced()

            Spacer()
            ProgressView().progressViewStyle(.linear)
        }
    }
    .padding(12)
}

#Preview(traits: .fixedLayout(width: 386, height: 1024)) {
    JobsManagerSidebarView()
}
