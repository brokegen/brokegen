import SwiftUI

func formatJson(_ jsonDict: [String : Any], indent: Int = 0) -> String {
    var stringMaker = ""
    for (k, v) in jsonDict {
        stringMaker += String(repeating: " ", count: indent)
        stringMaker += "\(k): \(v)\n"
    }

    return stringMaker
}

struct OneInferenceModelView: View {
    private var model: InferenceModel

    @State private var modelAvailable: Bool
    @State private var expandContent = false
    @State private var isHovered = false

    @Binding private var modelSelection: InferenceModel?
    private let enableModelSelection: Bool

    init(
        model: InferenceModel,
        modelAvailable: Bool,
        modelSelection: Binding<InferenceModel?>,
        enableModelSelection: Bool = true
    ) {
        self.model = model
        self.enableModelSelection = enableModelSelection
        self._modelAvailable = State(initialValue: modelAvailable)
        self._modelSelection = modelSelection
    }

    func expandContent(_ shouldExpandContent: Bool) -> Self {
        self.expandContent = shouldExpandContent
        return self
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    HStack {
                        if let modelSelectionServerId = modelSelection?.serverId {
                            if modelSelectionServerId == self.model.serverId {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 36))
                                    .padding(.trailing, 24)
                                    .foregroundStyle(Color.purple)
                            }
                        }
                        
                        Text(model.humanId)
                            .font(.system(size: 36))
                            .monospaced()
                            .foregroundStyle(modelAvailable ? Color.purple : Color(.controlTextColor))
                            .lineLimit(1...3)
                            .padding(.bottom, 8)
                    }

                    if let lastSeen = model.lastSeen {
                        Text("Last seen: " + String(describing: lastSeen))
                            .font(.subheadline)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if !self.expandContent {
                    self.expandContent = true
                }
                else {
                    if enableModelSelection {
                        modelSelection = model
                    }
                    else {
                        self.expandContent = false
                    }
                }
            }

            if expandContent {
                Divider()

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
