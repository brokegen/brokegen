import Foundation
import SwiftUI
import SwiftyJSON

struct ProviderPickerView: View {
    let providerService: ProviderService

    // TODO: data bindings for this are incorrect
    @State var providers: [ProviderClientModel] = []

    init(providerService: ProviderService) {
        self.providerService = providerService
    }

    var body: some View {
        ScrollView {
            if providers.isEmpty {
                Text("[no providers available]")
            }
            else {
                VStack(spacing: 24) {
                    ForEach(providers) { provider in
                        Text("\(provider.label.type) -- \(provider.label.id)")
                    }
                }
            }
        }
        .onAppear {
            Task {
                do {
                    providers.append(contentsOf: try await providerService.fetchAllProviders())
                }
                catch {}
            }
        }
    }
}
