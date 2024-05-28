import Combine
import SwiftUI

struct BlankOneSequenceView: View {
    @Environment(ChatSyncService.self) private var chatService
    let model: InferenceModel

    @State var promptInEdit: String = ""
    @State var submitting: Bool = false

    init(_ model: InferenceModel) {
        self.model = model
    }

    func submit() {
        Task.init {
            /// TODO: Figure out how to avoid race conditions and run this only once
            submitting = true
        }
    }

    func stopSubmitAndReceive() {
        submitting = false
    }

    var body: some View {
        List {
            HStack {
                InlineTextInput(textInEdit: $promptInEdit)
                    .padding(.top, 24)
                    .padding(.bottom, 24)
                    .border(.blue)
                    .disabled(submitting)
                    .onSubmit {
                        submit()
                    }

                VStack {
                    Button(action: stopSubmitAndReceive) {
                        let icon: String = {
                            if submitting {
                                return "stop.fill"
                            }
                            else {
                                return "stop"
                            }
                        }()
                        Image(systemName: icon)
                            .resizable()
                            .frame(width: 32, height: 32)
                            .disabled(!submitting)
                    }
                    .buttonStyle(.plain)
                    .help("Stop submitting or receiving")
                }
                .padding(.top, 16)
                .padding(.bottom, 12)
                .padding(.leading, 12)
                .padding(.trailing, -12)
            }
            .padding(.leading, 24)
            .padding(.trailing, 24)
        }
    }
}
