import Foundation
import SwiftUI
import SwiftyJSON

struct RefreshingRow: View {
    let providerType: String
    let providerId: String

    init(
        providerType: String,
        providerId: String
    ) {
        self.providerType = providerType
        self.providerId = providerId
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(providerType)
                    .fontWeight(.semibold)

                Text(providerId)
                    .foregroundStyle(Color(.disabledControlTextColor))
                    .monospaced()
            }
            .font(.system(size: 24))
            .lineLimit(1...4)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

struct ProvidersSidebar: View {
    @ObservedObject var providerService: ProviderService

    @State var providers: [ProviderClientModel] = []

    var body: some View {
        NavigationSplitView(sidebar: {
            AppSidebarSection(label: {
                Text("Available Providers")
            }) {
                Button("Refresh Providers", systemImage: "arrow.clockwise") {
                    Task { try? await providerService.fetchAllProviders() }
                }
                .foregroundStyle(Color.accentColor)
                .padding(.leading, -24)
                .padding(.trailing, -24)

                Divider()

                VStack(spacing: 24) {
                    ForEach(providers) { provider in
                        NavigationLink(destination: {
                            Text(provider.label.type)
                            Text(provider.label.id)
                        }, label: {
                            RefreshingRow(providerType: provider.label.type, providerId: provider.label.id)
                        })
                    }
                } // end of VStack
            }

            Text("End of loaded Providers")
                .foregroundStyle(Color(.disabledControlTextColor))
                .frame(height: 400)
                .frame(maxWidth: .infinity)

            Spacer()
        }, detail: {
            ProviderPickerView(providerService: providerService)
        })
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

struct ProviderPickerView: View {
    @ObservedObject var providerService: ProviderService

    @State var providers: [ProviderClientModel] = []

    var body: some View {
        ScrollView {
            if providers.isEmpty {
                Text("[no providers available]")
                    .frame(height: 400)
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
