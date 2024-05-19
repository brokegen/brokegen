import SwiftUI

struct JobsSidebarItem: View {
    @ObservedObject var job: Job

    init(job: Job) {
        self.job = job
    }

    var body: some View {
        HStack {
            Text(job.sidebarTitle)
                .font(.title2)
                .lineLimit(3)

            Spacer()

            switch job.status {
            case .notStarted:
                Image(systemName: "play")
                    .onTapGesture {
                        job.launch()
                    }

            case .requestedStart:
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 80)

            case .startedNoOutput:
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 80)
                Image(systemName: "stop")
                    .onTapGesture {
                        job.terminatePatiently()
                    }

            case .startedWithOutput:
                Image(systemName: "stop")
                    .onTapGesture {
                        job.terminatePatiently()
                    }

            case .requestedStop:
                ProgressView()
                    .frame(maxWidth: 80)
                Image(systemName: "stop.fill")
                    .onTapGesture {
                        job.terminate()
                    }

            case .stopped, .error:
                Image(systemName: "arrow.clockwise")
                    .onTapGesture {
                        job.launch()
                    }
            }
        }
        .frame(minHeight: 32)
    }
}

struct JobsManagerSidebarView: View {
    @Environment(JobsManagerService.self) private var jobsService

    var body: some View {
        Section(header: Text("Jobs")
            .font(.title2)
            .foregroundStyle(.primary)
            .padding(6)
        ) {
            ForEach(jobsService.renderableJobs) { job in
                NavigationLink(destination: JobOutputView(job: job)) {
                    JobsSidebarItem(job: job)
                }
            }
        }
    }
}

#Preview {
    VStack {
        Section(header: Text("Starting")) {
            JobsSidebarItem(job: TimeJob("notStarted").status(.notStarted))
            Divider()
            JobsSidebarItem(job: TimeJob("requestedStart").status(.requestedStart))
        }
        Section(header: Text("Started")) {
            JobsSidebarItem(job: TimeJob("startedNoOutput").status(.startedNoOutput))
            JobsSidebarItem(job: TimeJob("startedWithOutput").status(.startedWithOutput))
            JobsSidebarItem(job: TimeJob("requestedStop").status(.requestedStop))
            Divider()
            JobsSidebarItem(job: TimeJob("stopped").status(.stopped))
            JobsSidebarItem(job: TimeJob("error").status(.error))
        }
    }
    .padding(12)
}

#Preview(traits: .fixedLayout(width: 386, height: 1024)) {
    JobsManagerSidebarView()
}
