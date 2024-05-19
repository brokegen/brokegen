import SwiftUI

struct JobsSidebar: View {
    @Environment(JobsManagerService.self) private var jobsService: JobsManagerService
    let nestedNavLimit: Int?

    init(nestedNavLimit: Int? = 3) {
        self.nestedNavLimit = nestedNavLimit
    }

    var body: some View {
        if nestedNavLimit != nil && jobsService.renderableJobs.count > nestedNavLimit! {
            Section(header: Text("Jobs")
                .font(.title2)
                .foregroundStyle(.primary)
                .padding(6)
            ) {
                ForEach(jobsService.renderableJobs.prefix(nestedNavLimit!)) { job in
                    NavigationLink(destination: JobOutputView(job: job)) {
                        JobsSidebarItem(job: job)
                    }
                }

                NavigationLink(destination: NavigationSplitView {
                        JobsSidebar(nestedNavLimit: nil)
                    } detail: {
                        EmptyView()
                    }
                ) {
                    Text("[See all jobs]")
                        .font(.title2)
                        .frame(alignment: .trailing)
                }
            }
        }
        else {
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

            Spacer()
        }
    }
}
