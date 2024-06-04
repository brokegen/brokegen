import SwiftUI

struct InferenceModelSettingsView: View {
    @Environment(ProviderService.self) private var providerService
    
    @State var settings: InferenceModelSettings
    
    @State private var showDefaultInferenceModelPicker = false
    @State private var showFallbackInferenceModelPicker = false
    
    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Text("defaultInferenceModel: ")
                    .layoutPriority(0.2)
                
                Spacer()
                
                if let model = settings.defaultInferenceModel {
                    OneInferenceModelView(
                        model: model,
                        modelAvailable: true,
                        modelSelection: $settings.defaultInferenceModel,
                        enableModelSelection: true)
                    .layoutPriority(0.2)
                }
                else {
                    Button(action: {
                        showDefaultInferenceModelPicker = true
                    }) {
                        Text("Choose")
                    }
                }
            }
            
            HStack {
                Text("fallbackInferenceModel: ")
                    .layoutPriority(0.2)
                
                Spacer()
                
                if let model = settings.fallbackInferenceModel {
                    OneInferenceModelView(
                        model: model,
                        modelAvailable: true,
                        modelSelection: $settings.fallbackInferenceModel,
                        enableModelSelection: true)
                    .layoutPriority(0.2)
                }
                else {
                    Button(action: {
                        showFallbackInferenceModelPicker = true
                    }) {
                        Text("Choose")
                    }
                }
            }
        }
        .font(.system(size: 36))
        .sheet(isPresented: $showDefaultInferenceModelPicker) {
            ModelPickerView(modelSelection: $settings.defaultInferenceModel)
                .frame(width: 800, height: 1200, alignment: .top)
                .animation(.linear(duration: 0.2))
        }
        .sheet(isPresented: $showFallbackInferenceModelPicker) {
            ModelPickerView(modelSelection: $settings.fallbackInferenceModel)
                .frame(width: 800, height: 1200, alignment: .top)
                .animation(.linear(duration: 0.2))
        }
    }
}
