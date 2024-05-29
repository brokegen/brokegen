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
        let bigLink = NavigationLink(
            destination: NavigationSplitView(sidebar: {
                TallJobsSidebar()
            }, detail:{
                AllJobs(jobsService.renderableJobs)
            }
        )) {
            Text("Active Jobs")
                .font(.title2)
                .foregroundStyle(.primary)
                .padding(6)
        }

        ForEach(jobsService.specialJobs) { job in
            NavigationLink(destination: JobOutputView(job: job)) {
                JobsSidebarItem(job: job)
            }
        }

        Section(header: bigLink) {
            ForEach(jobsService.renderableJobs.prefix(navLimit)) { job in
                NavigationLink(destination: JobOutputView(job: job)) {
                    JobsSidebarItem(job: job)
                }
            }
        }

        Divider()

        NavigationLink(destination: AllJobs(jobsService.renderableJobs)
            .padding(32)
        ) {
            HStack {
                Text("[All Jobs]")
                    .font(.title2)
                    .padding(6)
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
            ForEach(jobsService.renderableJobs) { job in
                NavigationLink(destination: JobOutputView(job: job)) {
                    JobsSidebarItem(job: job)
                }
            }

            ForEach(jobsService.specialJobs) { job in
                NavigationLink(destination: InteractiveJobOutputView(job: job)) {
                    JobsSidebarItem(job: job)
                }
            }
        }

        Spacer()
    }
}
