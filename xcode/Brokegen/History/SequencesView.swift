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
                NavigationLink(destination: MultiMessageView(sequence.messages, submitter: { prompt in
                    guard sequence.serverId != nil else {
                        print("[ERROR] Can't submit chat request without a serverId")
                        return nil
                    }

                    let streamingResult = await chatService.generate(prompt, id: sequence.serverId!)
                    do {
                        // DEBUG: Add a sleep so we can notice any UI changes/freezing
                        try await Task.sleep(nanoseconds: 5 * NSEC_PER_SEC)
                        return streamingResult
                    }
                    catch {
                        print("[WARN] Exception occurred while trying to Task.sleep")
                        return streamingResult
                    }
                })) {
                    Text(
                        sequence.humanDesc ??
                        "ChatSequence #\(sequence.serverId!)")
                }
            }
            .padding(8)
        }
    }
}
