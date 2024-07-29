import Foundation
import SwiftUI
import SwiftyJSON

struct OneProviderView: View {
    @EnvironmentObject private var providerService: ProviderService

    let provider: ProviderClientModel

    @State private var expandNeverUsedModels: Bool = false

    var usedModels: [FoundationModel] {
        get {
            providerService.allModels
                .filter {
                    $0.latestInferenceEvent != nil
                    && $0.providerIdentifiers == provider.identifiers?.description
                }
        }
    }

    var neverUsedModels: [FoundationModel] {
        get {
            providerService.allModels
                .filter {
                    $0.latestInferenceEvent == nil
                    && $0.providerIdentifiers == provider.identifiers?.description
                }
        }
    }

    var body: some View {
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

        // MARK: - List the models from this Provider
        if !usedModels.isEmpty {
            ForEach(usedModels) { model in
                OneFoundationModelView(
                    model: model,
                    modelAvailable: .constant(false),
                    modelSelection: .constant(nil),
                    enableModelSelection: false
                )
            }
        }

        if expandNeverUsedModels {
            ForEach(neverUsedModels) { model in
                OneFoundationModelView(
                    model: model,
                    modelAvailable: .constant(false),
                    modelSelection: .constant(nil),
                    enableModelSelection: false
                )
            }
        }
        else {
            Toggle(isOn: $expandNeverUsedModels) {
                Label("Show \(neverUsedModels.count) never-used models", systemImage: "chevron.down")
                    .padding(24)
                    .font(.system(size: 24))
            }
            .toggleStyle(.button)
            .disabled(neverUsedModels.isEmpty)
        }
    }
}

struct MultiProviderView: View {
    @ObservedObject var providerService: ProviderService

    var body: some View {
        HStack(spacing: 24) {
            Button("Refresh Providers", systemImage: "arrow.clockwise") {
                providerService.fetchAllProviders(repeatUntilSuccess: false)
            }
            .buttonStyle(.accessoryBar)

            Spacer()
        }
        .padding(24)
        .font(.system(size: 18))

        Divider()

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(providerService.availableProviders) { provider in
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading) {
                            Text(provider.label.type)
                                .font(.system(size: 48))
                                .foregroundStyle(Color.accentColor)
                            Text(provider.label.id)
                                .font(.system(size: 30))
                        }

                        Spacer()

                        Button(action: {
                        }) {
                            Image(systemName: "arrow.clockwise")
                                .padding(12)
                            Text("Refresh Models")
                        }
                        .buttonStyle(.accessoryBar)
                        .font(.system(size: 18))
                        .disabled(true)
                    }
                    .padding(.horizontal, 24)

                    VFlowLayout(spacing: 24) {
                        OneProviderView(provider: provider)
                    }
                    .padding(24)

                    Divider()
                        .padding(24)
                }

                Text("End of loaded Providers")
                    .foregroundStyle(Color(.disabledControlTextColor))
                    .frame(height: 400)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
