import SwiftUI

struct MiniJobsSidebar: View {
    @Environment(JobsManagerService.self) private var jobsService: JobsManagerService
    let navLimit: Int

    init(navLimit: Int = 10) {
        self.navLimit = navLimit
    }

    var body: some View {
        AppSidebarSection(label: {
            HStack {
                Image(systemName: "checklist")
                    .padding(.trailing, 0)

                Text("Jobs")
            }
        }) {
            NavigationLink(destination: JobPickerView(jobsService.storedJobs)) {
                ASRow("All Jobs", showChevron: true)
            }

            if !jobsService.sidebarRenderableJobs.isEmpty && navLimit > 0 {
                Divider()

                ForEach(jobsService.sidebarRenderableJobs.prefix(navLimit)) { job in
                    NavigationLink(destination: JobOutputView(job: job)) {
                        JobsSidebarItem(job: job)
                            .padding(.leading, -24)
                            .padding(.trailing, -24)
                    }
                }
            }
        }

    }
}

struct TallJobsSidebar: View {
    @Environment(JobsManagerService.self) private var jobsService: JobsManagerService

    var body: some View {
        AppSidebarSection(label: {
            HStack {
                Image(systemName: "checklist")
                    .padding(.trailing, 0)

                Text("All Jobs")
            }
        }) {
            ForEach(jobsService.storedJobs) { job in
                NavigationLink(destination: JobOutputView(job: job)) {
                    JobsSidebarItem(job: job)
                }
            }
        }
    }
}
