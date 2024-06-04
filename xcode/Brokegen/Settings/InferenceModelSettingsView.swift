import SwiftUI

struct InferenceModelSettingsView: View {
    @Environment(ProviderService.self) private var providerService

    let settings: InferenceModelSettings

    var body: some View {
        Text("IMSV")
    }
}
