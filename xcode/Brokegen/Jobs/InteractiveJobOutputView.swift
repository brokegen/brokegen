import SwiftUI
import SwiftTerm
import AppKit

struct CustomTerminalWrapper: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return TerminalView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
    }
}

struct InteractiveJobOutputView: View {
    @ObservedObject var job: BaseJob

    var body: some View {
        ScrollViewReader { scrollViewProxy in
            RibbonView(job.ribbonText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .padding(.top, -20)
                .frame(maxHeight: 200)

            List {
                Text(job.displayedStatus)
                    .monospaced()
                    .font(.title2)

                CustomTerminalWrapper()

                Text(job.displayedOutput)
                    .monospaced()
                    .font(.title2)
            }

            Spacer()
        }
    }
}

#Preview(traits: .fixedLayout(width: 800, height: 800)) {
    struct OutputTest: View {
        let job: BaseJob

        init() {
            job = BaseJob()
            job.ribbonText = "XCODE PRÉVU"
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
