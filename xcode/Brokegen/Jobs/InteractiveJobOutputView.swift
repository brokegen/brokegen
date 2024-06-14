import AppKit
import Combine
import SwiftUI
import SwiftTerm

struct CustomTerminalWrapper: NSViewRepresentable {
    let underlying: TerminalView
    var subscription: AnyCancellable? = nil

    init(
        frame: CGRect,
        source textSource: Publishers.Sequence<String, Never>
    ) {
        underlying = TerminalView(frame: frame)

        subscription = textSource.sink(receiveValue: feed)
    }

    func makeNSView(context: Context) -> NSView {
        return underlying
    }

    func updateNSView(_ nsView: NSView, context: Context) {
    }

    func feed(c: Character) {
        underlying.getTerminal().feed(text: String(c))

        if c == "\n" {
            underlying.getTerminal().feed(text: "\r")
        }
    }

    func append(_ output: String) -> Self {
        underlying.getTerminal().feed(text: output)
        return self
    }
}

struct InteractiveJobOutputView: View {
    @ObservedObject var job: BaseJob

    var body: some View {
        VStack(spacing: 0) {
            RibbonView(job.ribbonText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .padding(.top, -20)
                .frame(maxHeight: 200)

            Divider()

            Text(job.displayedStatus)
                .monospaced()
                .font(.title2)

            GeometryReader { geometry in
                Text("frame: \(String(describing: geometry.frame(in: .local)))")

                CustomTerminalWrapper(frame: geometry.frame(in: .global), source: job.displayedOutput.publisher)
            }
        }
    }
}

#Preview(traits: .fixedLayout(width: 800, height: 800)) {
    struct OutputTest: View {
        let job: BaseJob

        init() {
            job = BaseJob()
            job.ribbonText = "XCODE PRÉVU"
            job.displayedStatus = "status: loaded small words"
            job.displayedOutput = """
loaded many words
beaucoup, beaucoup de mots, tu sais

c'est un peu
euh

i have eaten all the plums
"""
        }

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

        var body: some View {
            VStack {
                EmptyView()

                InteractiveJobOutputView(job: job)
                    .onAppear {
                        var stringBuilder = ""
                        for blockIndex in 1...40 {
                            stringBuilder.append(makeBlock(blockIndex))
                        }

                        job.displayedOutput = stringBuilder
                    }
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
