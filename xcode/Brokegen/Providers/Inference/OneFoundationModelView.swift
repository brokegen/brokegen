import SwiftUI
import SwiftyJSON

func formatJson(_ jsonDict: JSON?, prefix: String? = nil) -> String {
    let sortedDict = (jsonDict?.dictionaryValue ?? [:])
        .sorted { $0 < $1 }

    var stringMaker = ""

    for (k, v) in sortedDict {
        stringMaker += prefix ?? ""
        stringMaker += "\(k): \(v)\n"
    }

    return stringMaker
}

struct OneFoundationModelView: View {
    public static let preferredMaxWidth: CGFloat = 800

    private var model: FoundationModel

    @Binding private var modelAvailable: Bool
    @State private var expandContent: Bool
    @State private var isHovered = false

    @Binding private var modelSelection: FoundationModel?
    private let enableModelSelection: Bool

    init(
        model: FoundationModel,
        modelAvailable: Binding<Bool>,
        expandContent: Bool = false,
        modelSelection: Binding<FoundationModel?>,
        enableModelSelection: Bool = true
    ) {
        self.model = model
        self._modelAvailable = modelAvailable
        self._expandContent = State(initialValue: expandContent)

        self._modelSelection = modelSelection
        self.enableModelSelection = enableModelSelection
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

                if model.latestInferenceEvent != nil {
                    Grid {
                        GridRow {
                            Text("Tokens per second:")
                                .gridColumnAlignment(.leading)
                            Text(String(format: "%.3f", model.recentTokensPerSecond))
                                .gridColumnAlignment(.trailing)
                        }
                        .foregroundStyle(Color(.controlTextColor))
                        
                        GridRow {
                            Text("Recent inference event count:")
                            Text("\(model.recentInferenceEvents)")
                        }
                        .foregroundStyle(Color(.controlTextColor))
                        
                        Divider()
                        
                        GridRow {
                            Text("Latest inference event:")
                            Text(model.latestInferenceEvent!.ISO8601Format())
                        }
                    }
                    .frame(alignment: .leading)
                    .font(.system(size: 24))

                    Divider()
                }

                Group {
                    if !(model.displayStats?.dictionary?.isEmpty ?? true) {
                        Text("stats: \n" + formatJson(model.displayStats, prefix: "  "))
                            .lineLimit(1...)
                            .monospaced()
                            .padding(4)
                    }

                    Text(formatJson(model.modelIdentifiers))
                        .lineLimit(1...)
                        .monospaced()
                        .padding(4)
                }
                .padding(.bottom, 48)
            }
        }
        .listRowSeparator(.hidden)
        .padding(24)
        .onHover { isHovered in
            self.isHovered = isHovered
        }
        .background(
            Rectangle()
                .fill(isHovered ? Color(.controlHighlightColor) : Color.clear)
        )
    }
}

struct OFMPicker: View {
    let boxLabel: String
    @Binding var selectedModelBinding: FoundationModel?
    @Binding var showModelPicker: Bool
    let geometry: GeometryProxy
    let allowClear: Bool

    var body: some View {
        GroupBox(label: Text(boxLabel)
            .layoutPriority(0.2)
            .font(.system(size: 36))
        ) {
            VStack(alignment: .leading, spacing: 36) {
                if let model = selectedModelBinding {
                    OneFoundationModelView(
                        model: model,
                        modelAvailable: .constant(true),
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
