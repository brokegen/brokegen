import SwiftUI

struct JobPickerView: View {
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
