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

                    if model.label != nil {
                        Text("\(model.label!["type"]?.string ?? "[ProviderType]") -- \(model.label!["id"]?.string ?? "[ProviderLabel]")")
                            .font(.system(size: 24))
                            .foregroundStyle(Color(.disabledControlTextColor))
                    }

                    if let firstSeenAt = model.firstSeenAt {
                        Text("First seen: " + String(describing: firstSeenAt))
                            .font(.system(size: 24))
                            .foregroundStyle(Color(.disabledControlTextColor))
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

                    Text(formatJson(model.modelIdentifiers ?? [:]))
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

struct OIMPicker: View {
    let boxLabel: String
    @Binding var selectedModelBinding: InferenceModel?
    @Binding var showModelPicker: Bool
    let geometry: GeometryProxy
    let allowClear: Bool

    var body: some View {
        GroupBox(label:
                    Text(boxLabel)
            .monospaced()
            .layoutPriority(0.2)
            .font(.system(size: 36))
        ) {
            VStack(alignment: .leading, spacing: 36) {
                if let model = selectedModelBinding {
                    OneInferenceModelView(
                        model: model,
                        modelAvailable: true,
                        modelSelection: $selectedModelBinding,
                        enableModelSelection: true)

                    HStack(alignment: .bottom, spacing: 0) {
                        Button(action: {
                            showModelPicker = true
                        }) {
                            Text("Reselect Model")
                                .font(.system(size: 24))
                                .padding(12)
                        }

                        Spacer()
                            .frame(minWidth: 0)

                        Button(action: {
                            selectedModelBinding = nil
                        }) {
                            Text("Clear Model Selection")
                                .font(.system(size: 24))
                                .padding(12)
                        }
                        .disabled(!allowClear)
                    }
                }
                else {
                    Button(action: {
                        showModelPicker = true
                    }) {
                        Text("Select Model")
                            .font(.system(size: 24))
                            .padding(12)
                    }
                }
            }
            .padding(36)
            .frame(minHeight: 144)

            Spacer()
                .frame(maxWidth: .infinity, maxHeight: 0)
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerView(modelSelection: $selectedModelBinding)
            // Frame is very wide because the way we're positioning incorrectly ignores the sidebar
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height * 0.8,
                    alignment: .top)
                .animation(.linear(duration: 0.2))
        }
        .frame(minHeight: 160)
    }
}
