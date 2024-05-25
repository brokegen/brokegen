import SwiftUI

struct SequencesView: View {
    @Environment(ChatSyncService.self) private var chatService

    var body: some View {
        List {
            Button("Import", systemImage: "paperplane") {
                chatService.fetchPinnedSequences()
            }
            .buttonStyle(.accessoryBar)

            ForEach(chatService.loadedSequences.filter {seq in
                !seq.messages.isEmpty
            }) { sequence in
                NavigationLink(destination: MultiMessageView(sequence.messages)) {
                    Text(
                        sequence.humanDesc ??
                        "ChatSequence #\(sequence.serverId!)")
                }
            }
            .padding(8)
        }
    }
}
