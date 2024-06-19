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
            NavigationLink(destination: {
                NavigationSplitView(sidebar: {
                    ScrollView {
                        TallJobsSidebar()
                    }
                }, detail: {
                    JobPickerView(jobsService.storedJobs)
                })
            }) {
                ASRow("All Jobs", showChevron: true)
            }

            if !jobsService.sidebarRenderableJobs.isEmpty && navLimit > 0 {
                Divider()

                ForEach(jobsService.sidebarRenderableJobs.prefix(navLimit)) { job in
                    NavigationLink(destination: JobOutputView(job: job)) {
                        JobsSidebarItem(job: job)
                            .padding(.leading, -JobsSidebarItem.LEADING_BUTTON_WIDTH)
                            .padding(.trailing, -JobsSidebarItem.TRAILING_INDICATOR_WIDTH)
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
