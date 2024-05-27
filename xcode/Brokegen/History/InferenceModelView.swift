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
                    Text(model.humanId)
                        .font(.title)
                        .monospaced()
                        .lineLimit(2)
                        .padding(.bottom, 8)

                    if let lastSeen = model.lastSeen {
                        Text("Last seen: " + String(describing: lastSeen))
                            .font(.subheadline)
                    }

                    Divider()

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
                .padding(12)
                .lineLimit(4)
            }
            .padding(8)
        }
        .frame(maxWidth: 800)
        .onAppear {
            providerService.fetchAvailableModels()
        }
    }
}
