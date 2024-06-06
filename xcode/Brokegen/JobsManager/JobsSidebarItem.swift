import SwiftUI

struct JobsSidebarItem: View {
    @ObservedObject var job: BaseJob

    @State var isButtonHovered = false

    static let LEADING_BUTTON_WIDTH: CGFloat = 24
    static let TRAILING_PROGRESS_WIDTH: CGFloat = 80
    static let TRAILING_INDICATOR_WIDTH: CGFloat = 24

    init(job: BaseJob) {
        self.job = job
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Group {
                switch job.status {
                case .notStarted:
                    Image(systemName: self.isButtonHovered ? "play.fill" : "play")
                        .onTapGesture {
                            _ = job.launch()
                        }

                case .requestedStart:
                    Image(systemName: "play.fill")
                        .disabled(true)
                        .foregroundStyle(Color(.disabledControlTextColor))

                case .startedNoOutput, .startedWithOutput:
                    Image(systemName: self.isButtonHovered ? "stop.fill" : "stop")
                        .onTapGesture {
                            _ = job.terminatePatiently()
                        }

                case .requestedStop:
                    Image(systemName: "stop.fill")
                        .foregroundStyle(self.isButtonHovered ? Color.red : Color(.controlTextColor))
                        .onTapGesture {
                            _ = job.terminate()
                        }

                case .stopped, .error:
                    Image(systemName: self.isButtonHovered ? "play.fill" : "arrow.clockwise")
                        .onTapGesture {
                            _ = job.launch()
                        }
                }
            }
            .frame(width: JobsSidebarItem.LEADING_BUTTON_WIDTH)
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
                        .frame(maxWidth: JobsSidebarItem.TRAILING_PROGRESS_WIDTH)

                case .startedNoOutput:
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(maxWidth: JobsSidebarItem.TRAILING_PROGRESS_WIDTH)

                case .startedWithOutput:
                    Image(systemName: "bolt.horizontal.fill")
                        .foregroundStyle(.green)
                        .frame(maxWidth: JobsSidebarItem.TRAILING_INDICATOR_WIDTH)

                case .requestedStop:
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: JobsSidebarItem.TRAILING_INDICATOR_WIDTH)

                case .error:
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.red)

                case _:
                    EmptyView()
                }
            }
            .layoutPriority(0.2)
        }
    }
}

/// This is only used in #Preview
extension TimeJob {
    func setStatus(_ status: JobStatus) -> Self {
        self.status = status
        return self
    }
}

#Preview(traits: .fixedLayout(width: 384, height: 768)) {
    List {
        Section(header: Text("Starting")
            .padding([.top], 32)
            .padding([.bottom], 12)
            .font(.title)
            .foregroundStyle(.primary)
        ) {
            JobsSidebarItem(job: TimeJob(
                "row0 -- extremely long row name\n" +
                "with 😡😠, damn multibyte unicode chars")
                .setStatus(.notStarted))
            JobsSidebarItem(job: TimeJob("row1").setStatus(.requestedStart))
        }
        .padding(8)

        Section(header: Text("Started")
            .padding([.top], 32)
            .padding([.bottom], 12)
            .font(.title)
            .foregroundStyle(.primary)
        ) {
            JobsSidebarItem(job: TimeJob("row2").setStatus(.startedNoOutput))
            JobsSidebarItem(job: TimeJob("row3").setStatus(.startedWithOutput))
            JobsSidebarItem(job: TimeJob("row4").setStatus(.requestedStop))
            JobsSidebarItem(job: TimeJob("row5").setStatus(.stopped))
            JobsSidebarItem(job: TimeJob("row6").setStatus(.error("sidebar, eh")))
        }
        .padding(8)
        .background(Color(.controlBackgroundColor))
    }
    .frame(maxHeight: .infinity)
    .font(.system(size: 16))
}
