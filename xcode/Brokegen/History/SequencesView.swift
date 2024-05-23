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
                Text("Sequence \(sequence.id)")

                let message = sequence.messages.last!

//                Text("ChatSequence")
//                    .font(.title2)
//                    .color(.accentColor)

                VStack(alignment: .leading) {
                    Text(message.createdAt != nil
                         ? String(describing: message.createdAt!) : "")
                        .monospaced()
                        .opacity(message.createdAt != nil ? 1 : 0)
                    Spacer()
                    Text(message.content)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(8)
        }
    }
}
