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

    @ViewBuilder
    func providerDetail(_ provider: ProviderClientModel) -> some View {
        VFlowLayout(spacing: 24) {
            GroupBox(content: {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                    GridRow {
                        Text("Type")
                        Text(provider.label.type)
                    }
                    GridRow {
                        Text("ID")
                        Text(provider.label.id)
                    }
                }
            }, label: {
                Text("Provider label")
                    .font(.system(size: 24).lowercaseSmallCaps())
                    .gridCellColumns(2)
            })
            .frame(maxWidth: 800)

            GroupBox(content: {
                Grid(alignment: .topLeading, horizontalSpacing: 24, verticalSpacing: 12) {
                    GridRow {
                        Text("identifiers")
                        Text(provider.identifiers?.description ?? "[no identifiers]")
                    }
                    GridRow {
                        Text("machine info")
                        Text(provider.machineInfo?.description ?? "[no machineInfo]")
                            .frame(maxHeight: .infinity)
                    }
                    GridRow {
                        Text("human info")
                        Text(provider.humanInfo?.description ?? "[no humanInfo]")
                    }
                }
            }, label: {
                Text("Provider detail")
                    .font(.system(size: 24).lowercaseSmallCaps())
                    .gridCellColumns(2)
            })
            .frame(maxWidth: 800, maxHeight: .infinity)
        }
        .lineLimit(nil)
        .monospaced()
        .font(.system(size: 18))
    }

    var body: some View {
        NavigationSplitView(sidebar: {
            AppSidebarSection(label: {
                Text("Available Providers")
            }) {
                Button("Refresh Providers", systemImage: "arrow.clockwise") {
                    providerService.fetchAllProviders(repeatUntilSuccess: false)
                }
                .foregroundStyle(Color.accentColor)
                .padding(.leading, -24)
                .padding(.trailing, -24)

                Divider()

                ScrollView {
                    LazyVStack(spacing: 24) {
                        ForEach(providerService.availableProviders) { provider in
                            NavigationLink(destination: {
                                providerDetail(provider)
                            }, label: {
                                RefreshingRow(providerType: provider.label.type, providerId: provider.label.id)
                            })
                        }
                    } // end of VStack
                }
            }

            Text("End of loaded Providers")
                .foregroundStyle(Color(.disabledControlTextColor))
                .frame(height: 400)
                .frame(maxWidth: .infinity)

            Spacer()
        }, detail: {
            ProviderPickerView(providerService: providerService)
                .font(.system(size: 36))
        })
    }
}

// TODO: Rename this to something more fitting, like CombinedProviderList
struct ProviderPickerView: View {
    @ObservedObject var providerService: ProviderService

    var body: some View {
        ScrollView {
            if providerService.availableProviders.isEmpty {
                Text("[no providers available]")
                    .frame(height: 400)
            }
            else {
                VStack(spacing: 24) {
                    ForEach(providerService.availableProviders) { provider in
                        Text("\(provider.label.type) -- \(provider.label.id)")
                    }
                }
            }
        }
    }
}
