import Foundation
import SwiftUI
import SwiftyJSON

struct RefreshingRow: View {
    let text: String
    let showChevron: Bool

    init(
        _ text: String,
        showChevron: Bool = false
    ) {
        self.showChevron = showChevron
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(text)
                .lineLimit(1...2)
                .layoutPriority(0.5)
            Spacer()
            if showChevron {
                Image(systemName: "bubble.fill")
                    .padding(.trailing, -12)
                    .font(.system(size: 10))
            }
        }
        .contentShape(Rectangle())
    }
}

struct ProvidersSidebar: View {
    @ObservedObject var providerService: ProviderService

    @State var providers: [ProviderClientModel] = []

    var body: some View {
        NavigationSplitView(sidebar: {
            AppSidebarSection(label: {
                Text("All Providers")
            }) {
                VStack(spacing: 24) {
                    ForEach(providers) { provider in
                        NavigationLink(destination: {
                            Text(provider.label.id)
                            Text(provider.label.type)
                        }, label: {
                            RefreshingRow(provider.label.id)
                        })
                    }
                } // end of VStack
            }

            Text("End of loaded Providers")
                .foregroundStyle(Color(.disabledControlTextColor))
                .frame(height: 400)
                .frame(maxWidth: .infinity)
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
