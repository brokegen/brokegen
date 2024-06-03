import SwiftUI

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

    init(model: InferenceModel, showAddButton: Bool = true) {
        self.model = model
        self.showAddButton = showAddButton
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    Text(model.humanId)
                        .font(.title)
                        .monospaced()
                        .foregroundStyle(modelAvailable ? Color.accentColor : Color(.controlTextColor))
                        .lineLimit(2)
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
            }
        }
        .padding(12)
        .listRowSeparator(.hidden)
        .padding(.bottom, 48)
    }
}
