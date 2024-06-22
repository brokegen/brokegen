import SwiftUI

struct JobOutputView: View {
    @ObservedObject var job: BaseJob

    var splitOutput: [String] {
        get {
            return job.displayedOutput.split(separator: "\n").map { String($0) }
        }
    }

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 0) {
                RibbonView(job.ribbonText)

                Text(job.displayedStatus)
                    .monospaced()
                    .font(.title2)
            }
            .frame(maxWidth: .infinity)
            .lineLimit(1...)
            .padding([.leading, .trailing], 16)
            .padding(.bottom, 24)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<splitOutput.count, id: \.self) { index in
                        Text(splitOutput[index])
                            .monospaced()
                            .font(.title2)
                    }
                }
                .padding([.leading, .trailing], 24)
            }
        }
        .padding(.top, -20)
    }
}

#Preview(traits: .fixedLayout(width: 1328, height: 1328)) {
    struct ViewHolder: View {
        let job = BaseJob()

        private func makeBlock(_ index: Int) -> String {
            var stringBuilder = ""
            stringBuilder.append("Block #\(index)\n")
            stringBuilder.append("==========\n")

            for _ in 1...20 {
                for _ in 1...7 {
                    stringBuilder.append("0123456789 ")
                }
                stringBuilder.append("\n")
            }
            stringBuilder.append("\n")

            return stringBuilder
        }

        init() {
            job.ribbonText = "XCODE PRÉVU for long text"
            job.displayedStatus = "loaded"

            var stringBuilder = ""
            for blockIndex in 1...40 {
                stringBuilder.append(makeBlock(blockIndex))
            }

            job.displayedOutput = stringBuilder
        }

        var body: some View {
            JobOutputView(job: job)
                .onAppear {
                    job.displayedOutput.append("\n")
                }
        }
    }

    return ViewHolder()
}

#Preview(traits: .fixedLayout(width: 800, height: 800)) {
    struct OutputTest: View {
        let job: BaseJob

        init() {
            job = BaseJob()
            job.ribbonText = "XCODE PRÉVU for resizing"
            job.displayedStatus = "loaded small words"
            job.displayedOutput = """
loaded many words
beaucoup, beaucoup de mots, tu sais

c'est un peu
euh

i have eaten all the plums
"""
        }

        var body: some View {
            NavigationView {
                EmptyView()

                JobOutputView(job: job)
            }
        }
    }

    return OutputTest()
}

#Preview {
    JobOutputView(job: TimeJob("Xcode preview"))
        .fixedSize()
        .frame(minHeight: 400)
}
