import SwiftUI

struct InferenceModelView: View {
    @Environment(ProviderService.self) private var providerService

    func formatJson(_ jsonDict: [String : Any], indent: Int = 0) -> String {
        var stringMaker = ""
        for (k, v) in jsonDict {
            stringMaker += String(repeating: " ", count: indent)
            stringMaker += "\(k): \(v)\n"
        }

        return stringMaker
    }

    var body: some View {
        List {
            ForEach(providerService.availableModels) { model in
                VStack(alignment: .leading) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading) {
                            Text(model.humanId)
                                .font(.title)
                                .monospaced()
                                .foregroundColor(.accentColor)
                                .lineLimit(2)
                                .padding(.bottom, 8)

                            if let lastSeen = model.lastSeen {
                                Text("Last seen: " + String(describing: lastSeen))
                                    .font(.subheadline)
                            }
                        }

                        Spacer()

                        NavigationLink(destination: BlankOneSequenceView(model)) {
                            Image(systemName: "plus.message")
                                .resizable()
                                .frame(width: 48, height: 48)
                                .padding(6)
                        }
                    }

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
                    .background(Color(.controlBackgroundColor))
                }
                .padding(12)
                .background(Color(.controlBackgroundColor))
                .listRowSeparator(.hidden)
                .padding(.bottom, 48)
            }
        }
        .frame(maxWidth: 800)
        .onAppear {
            providerService.fetchAvailableModels()
        }
    }
}
