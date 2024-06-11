import SwiftUI

struct JobPickerView: View {
    let jobs: [BaseJob]

    init(_ jobs: [BaseJob]) {
        self.jobs = jobs
    }

    var body: some View {
        ScrollView {
            VFlowLayout(spacing: 36) {
                ForEach(jobs) { job in
                    NavigationLink(destination: JobOutputView(job: job)) {
                        JobsSidebarItem(job: job)
                            .padding(12)
                    }
                }
            }
        }
        .font(.system(size: 18))
    }
}
