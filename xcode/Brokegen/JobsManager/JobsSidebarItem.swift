import SwiftUI

struct JobsSidebarItem: View {
    @ObservedObject var job: BaseJob

    static let LEADING_MARGIN: CGFloat = 24
    static let PROGRESS_WIDTH: CGFloat = 80
    static let BUTTON_WIDTH: CGFloat = 32

    init(job: BaseJob) {
        self.job = job
    }

    var body: some View {
        HStack(alignment: .top) {
            Group {
                switch job.status {
                case .notStarted:
                    Image(systemName: "play")
                        .onTapGesture {
                            _ = job.launch()
                        }

                case .startedNoOutput, .startedWithOutput:
                    Image(systemName: "stop")
                        .onTapGesture {
                            _ = job.terminatePatiently()
                        }

                case .requestedStop:
                    Image(systemName: "stop.fill")
                        .onTapGesture {
                            _ = job.terminate()
                        }

                case .stopped, .error:
                    Image(systemName: "arrow.clockwise")
                        .onTapGesture {
                            _ = job.launch()
                        }

                case _:
                    Spacer()

                }
            }
            .frame(width: JobsSidebarItem.LEADING_MARGIN)
            .layoutPriority(0.5)

            Text(job.sidebarTitle)
                .lineLimit(1...4)
                .layoutPriority(1.0)

            Spacer()

            Group {
                switch job.status {
                case .requestedStart:
                    ProgressView()
                        .progressViewStyle(.linear)
                        .padding([.trailing], JobsSidebarItem.LEADING_MARGIN + 4)
                        .frame(maxWidth: JobsSidebarItem.PROGRESS_WIDTH + JobsSidebarItem.BUTTON_WIDTH + 6)

                case .startedNoOutput:
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 80)

                case .startedWithOutput:
                    Image(systemName: "bolt.horizontal.fill")
                        .controlSize(.extraLarge)
                        .foregroundStyle(.green)
                        .frame(maxWidth: JobsSidebarItem.LEADING_MARGIN)

                case .requestedStop:
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: 32)

                case _:
                    EmptyView()
                }
            }
            .layoutPriority(0.2)
        }
        .font(.system(size: 16))
        .frame(minHeight: 32)
    }
}

#Preview(traits: .fixedLayout(width: 384, height: 512)) {
    VStack(alignment: .leading) {
        Section(header: Text("Starting")
            .padding([.top], 32)
            .padding([.bottom], 12)
            .font(.title)
            .foregroundStyle(.primary)
        ) {
            JobsSidebarItem(job: TimeJob(
                "row0 -- extremely long row name\n" +
                "with 😡😠, damn multibyte unicode chars")
                .status(.notStarted))
            JobsSidebarItem(job: TimeJob("row1").status(.requestedStart))
        }

        Section(header: Text("Started")
            .padding([.top], 32)
            .padding([.bottom], 12)
            .font(.title)
            .foregroundStyle(.primary)
        ) {
            JobsSidebarItem(job: TimeJob("row2").status(.startedNoOutput))
            JobsSidebarItem(job: TimeJob("row3").status(.startedWithOutput))
            JobsSidebarItem(job: TimeJob("row4").status(.requestedStop))
            Divider()
            JobsSidebarItem(job: TimeJob("row5").status(.stopped))
            JobsSidebarItem(job: TimeJob("row6").status(.error("sidebar, eh")))
        }
    }
    .frame(maxHeight: .infinity)
    .padding(12)
}
