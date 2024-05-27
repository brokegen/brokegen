import SwiftUI

struct InferenceModelView: View {
    @Environment(ProviderService.self) private var providerService

    var body: some View {
        List {
            ForEach(providerService.availableModels) { model in
                VStack(alignment: .leading) {
                    Text(model.humanId)
                        .font(.title)
                        .monospaced()
                        .padding(.bottom, 8)

                    Text(model.providerIdentifiers)
                        .monospaced()

                    Text(String(describing: model.modelIdentifiers))
                        .monospaced()

                    if let lastSeen = model.lastSeen {
                        Text(String(describing: lastSeen))
                            .font(.subheadline)
                    }
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
