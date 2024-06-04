import SwiftUI
import AppKit

struct WaveShape: Shape {
    // how high our waves should be
    var strength: Double

    // how frequent our waves should be
    var frequency: Double

    // how much to offset our waves horizontally
    var phase: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()

        // calculate some important values up front
        let width = Double(rect.width)
        let height = Double(rect.height)
        let midWidth = width / 2
        let midHeight = height / 2

        // split our total width up based on the frequency
        let wavelength = width / frequency

        // start at the left center
        path.move(to: CGPoint(x: 0, y: midHeight))

        // now count across individual horizontal points one by one
        for x in stride(from: 0, through: width, by: 1) {
            // find our current position relative to the wavelength
            let relativeX = x / wavelength

            // calculate the sine of that position
            let sine = sin(relativeX + phase)

            // multiply that sine by our strength to determine final offset, then move it down to the middle of our view
            let y = strength * sine + midHeight

            // add a line to here
            path.addLine(to: CGPoint(x: x, y: y))
        }

        return Path(path.cgPath)
    }

    var animatableData: Double {
        get { phase }
        set { self.phase = newValue }
    }
}

struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        Path() { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            p.closeSubpath()
        }
    }
}

func formatJson(_ jsonDict: [String : Any], indent: Int = 0) -> String {
    var stringMaker = ""
    for (k, v) in jsonDict {
        stringMaker += String(repeating: " ", count: indent)
        stringMaker += "\(k): \(v)\n"
    }

    return stringMaker
}

struct OneInferenceModel: View {
    var model: InferenceModel
    let showAddButton: Bool

    @State var modelAvailable = true
    @State var expandContent = false
    @State var isHovered = false

    init(
        model: InferenceModel,
        showAddButton: Bool = true,
        modelAvailable: Bool
    ) {
        self.model = model
        self.showAddButton = showAddButton
        self.modelAvailable = modelAvailable
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    Text(model.humanId)
                        .font(.system(size: 36))
                        .monospaced()
                        .foregroundStyle(modelAvailable ? Color.purple : Color(.controlTextColor))
                        .lineLimit(1...3)
                        .padding(.bottom, 8)

                    if let lastSeen = model.lastSeen {
                        Text("Last seen: " + String(describing: lastSeen))
                            .font(.subheadline)
                    }
                }

                if showAddButton {
                    Spacer()

                    NavigationLink(destination: BlankOneSequenceView(model)) {
                        Image(systemName: "plus.message")
                            .resizable()
                            .frame(width: 48, height: 48)
                            .padding(6)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                self.expandContent = !self.expandContent
            }

            Divider()

            if expandContent {
                Group {
                    if model.stats != nil {
                        Text("stats: \n" + formatJson(model.stats!, indent: 2))
                            .lineLimit(1...)
                            .monospaced()
                            .padding(4)
                    }

                    Text(formatJson(model.modelIdentifiers!))
                        .lineLimit(1...)
                        .monospaced()
                        .padding(4)
                }
                .padding(.bottom, 48)
            }
        }
        .listRowSeparator(.hidden)
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color(.controlHighlightColor) : Color.clear)
                .border(Color(.controlTextColor))
        )
        .onHover { isHovered in
            self.isHovered = isHovered
        }
    }
}

#Preview {
    @State var isHovered = false
    @State var phase = 0.0

    return Text("Overlaid")
        .frame(width: 300, height: 200)
        .background(
            Rectangle()
                .fill(isHovered ? Color(.controlHighlightColor) : Color.clear)
                .clipShape(
                    RoundedRectangle(cornerRadius: 6)
                )
                .overlay(
                    WaveShape(strength: 50, frequency: 30, phase: phase)
                        .stroke(.red, lineWidth: 2)
                )
        )
        .onAppear {
            withAnimation(Animation.linear(duration: 1).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
}
