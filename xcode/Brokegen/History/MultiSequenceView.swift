import SwiftUI

struct MultiSequenceView: View {
    @Environment(ChatSyncService.self) private var chatService

    var body: some View {
        List {
            Button("Refresh", systemImage: "paperplane") {
                chatService.fetchPinnedSequences()
            }
            .buttonStyle(.accessoryBar)

            ForEach(chatService.loadedSequences.filter { s in
                !s.messages.isEmpty
            }) { sequence in
                NavigationLink(destination: OneSequenceView(sequence)) {
                    VStack {
                        let longTitle: String =
                            (sequence.humanDesc ?? "ChatSequence #\(sequence.serverId!)") +
                            " -- \(sequence.messages.count) messages"
                        Text(longTitle)
                            .font(.headline)

                        if let subTitle = sequence.messages.last?.createdAt {
                            Text(String(describing: subTitle))
                                .font(.subheadline)
                        }
                    }
                }
                .padding(12)
                .lineLimit(4)
            }
            .padding(8)
        }
        .frame(maxWidth: 800)
    }
}
