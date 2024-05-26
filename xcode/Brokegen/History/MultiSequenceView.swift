import SwiftUI

struct MultiSequenceView: View {
    @Environment(ChatSyncService.self) private var chatService

    var body: some View {
        List {
            Button("Import", systemImage: "paperplane") {
                chatService.fetchPinnedSequences()
            }
            .buttonStyle(.accessoryBar)

            ForEach(chatService.loadedSequences.filter { s in
                !s.messages.isEmpty
            }) { sequence in
                NavigationLink(destination: OneSequenceView(sequence)) {
                    Text(
                        sequence.humanDesc ??
                        "ChatSequence #\(sequence.serverId!)")
                }
            }
            .padding(8)
        }
    }
}
