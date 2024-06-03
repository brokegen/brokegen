import SwiftUI

struct AllJobs: View {
    let jobs: [BaseJob]

    init(_ jobs: [BaseJob]) {
        self.jobs = jobs
    }

    var body: some View {
        RadialLayout {
            ForEach(jobs) { job in
                NavigationLink(destination: JobOutputView(job: job)) {
                    JobsSidebarItem(job: job)
                }
            }
        }
    }
}

struct MiniJobsSidebar: View {
    @Environment(JobsManagerService.self) private var jobsService: JobsManagerService
    let navLimit: Int

    init(navLimit: Int = 10) {
        self.navLimit = navLimit
    }

    var body: some View {
        Section(header: HStack {
            Image(systemName: "checklist")
                .font(.system(size: 24))
                .foregroundStyle(Color(.controlTextColor))
                .padding(.leading, 4)
                .padding(.trailing, -8)

            Text("Jobs")
                .font(.system(size: 24))
                .foregroundStyle(Color(.controlTextColor))
                .padding(8)
        }) {
            Divider()

            NavigationLink(destination: AllJobs(jobsService.storedJobs)) {
                HStack {
                    Text("Available Jobs")
                        .font(.title2)
                        .padding(6)
                        .layoutPriority(0.5)
                    Spacer()
                    Image(systemName: "chevron.right")
                }
            }

            if !jobsService.sidebarRenderableJobs.isEmpty && navLimit > 0 {
                Divider()

                ForEach(jobsService.sidebarRenderableJobs.prefix(navLimit)) { job in
                    NavigationLink(destination: JobOutputView(job: job)) {
                        JobsSidebarItem(job: job)
                    }
                }
            }
        }

    }
}

struct TallJobsSidebar: View {
    @Environment(JobsManagerService.self) private var jobsService: JobsManagerService

    var body: some View {
        Section(header: Text("ALL JOBS")
            .font(.title2)
            .foregroundStyle(.primary)
            .padding(6)
        ) {
            ForEach(jobsService.storedJobs) { job in
                NavigationLink(destination: InteractiveJobOutputView(job: job)) {
                    JobsSidebarItem(job: job)
                }
            }
        }

        Spacer()
    }
}
