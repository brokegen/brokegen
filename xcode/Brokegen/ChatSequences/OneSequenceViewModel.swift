import Alamofire
import Combine
import Foundation
import MarkdownUI
import SwiftData
import SwiftyJSON

let maxPinChatSequenceDesc = 140

/// This class is usually owned by ChatSyncService.
/// Interesting side cases:
///
/// - on constructing a new Sequence, there's no ChatSequenceID from the server yet
/// - when constructing a response / having one sent down from the server, the ChatSequenceID is not created until the response is done sending.
///   as you might imagine, this gets _weird_.
///
@Observable
class OneSequenceViewModel {
    var sequence: ChatSequence
    @ObservationIgnored private var prerenderedMessages: [MessageLike : MarkdownContent] = [:]
    let chatService: ChatSyncService
    let settings: CSCSettingsService.SettingsProxy
    let chatSettingsService: CSCSettingsService
    let appSettings: AppSettings

    var promptInEdit: String = ""
    var submitting: Bool = false

    @ObservationIgnored var incompleteResponseData: Data? = nil
    @ObservationIgnored var bufferedServerStatus: String = ""
    @ObservationIgnored var bufferedResponseContent: String = ""
    @ObservationIgnored var bufferedResponseLastFlush: Date = Date.distantPast
    var responseInEdit: TemporaryChatMessage? = nil
    @ObservationIgnored private var receivedDone: Int = -1
    @ObservationIgnored private var receivedError: Int = -1
    var receiving: Bool {
        /// This field does double duty to indicate whether we are currently receiving data.
        /// `nil` before first data, and then reset to `nil` once we're done receiving.
        get { responseInEdit != nil }
    }

    @ObservationIgnored var submittedAssistantResponseSeed: String? = nil
    @ObservationIgnored private var receivingStreamer: AnyCancellable? = nil
    var serverStatus: String? = nil

    private var stayAwake: StayAwake = StayAwake()
    var currentlyAwakeDuringInference: Bool {
        get { stayAwake.assertionIsActive }
    }

    // MARK: - Options and Configurations
    var showTextEntryView: Bool = true
    var showUiOptions: Bool = false
    var showInferenceOptions: Bool = false
    var showRetrievalOptions: Bool = false

    var continuationInferenceModel: FoundationModel? = nil
    var showAssistantResponseSeed: Bool = false
    var showSystemPromptOverride: Bool = false

    convenience init(_ sequence: ChatSequence, chatService: ChatSyncService, appSettings: AppSettings, chatSettingsService: CSCSettingsService) {
        self.init(
            sequence: sequence,
            chatService: chatService,
            settings: chatSettingsService.settings(for: sequence.serverId),
            chatSettingsService: chatSettingsService,
            appSettings: appSettings
        )
    }

    init(
        sequence: ChatSequence,
        chatService: ChatSyncService,
        settings: CSCSettingsService.SettingsProxy,
        chatSettingsService: CSCSettingsService,
        appSettings: AppSettings
    ) {
        self.sequence = sequence
        self.chatService = chatService
        self.settings = settings
        self.chatSettingsService = chatSettingsService
        self.appSettings = appSettings

        prerenderMessages()
    }

    var displayHumanDesc: String {
        return sequence.displayHumanDesc()
    }

    var displayServerStatus: String? {
        get {
            if serverStatus == nil || serverStatus!.isEmpty {
                return nil
            }

            return serverStatus
        }
    }

    func prerenderMessages() {
        for message in sequence.messages {
            _ = lookup(message)
        }
    }

    func lookup(_ message: MessageLike) -> MarkdownContent {
        if let rendered = prerenderedMessages[message] {
            return rendered
        }
        else {
            let rendered = MarkdownContent(message.content)
            prerenderedMessages[message] = rendered
            return rendered
        }
    }

    func refreshSequenceData() {
        Task {
            if let refreshedSequence = try? await chatService.fetchChatSequenceDetails(sequence.serverId) {
                DispatchQueue.main.async {
                    self.chatService.updateSequence(withSameId: refreshedSequence)
                }
            }
        }
    }

    private func completionHandler(
        caller callerName: String,
        endpoint: String
    ) -> ((Subscribers.Completion<AFErrorAndData>) -> Void) {
        return { [self] completion in
            _ = self.stayAwake.destroyAssertion()

            switch completion {
            case .finished:
                if receivedDone != 1 {
                    print("[ERROR] \(callerName) completed, but received \(receivedDone) \"done\" chunks")
                }
                if incompleteResponseData != nil {
                    print("[ERROR] \(callerName) dropping \(incompleteResponseData!.count) bytes of unparsed JSON")
                    incompleteResponseData = nil
                }

                stopSubmitAndReceive()
                serverStatus = nil

            case .failure(let errorAndData):
                stopSubmitAndReceive()

                let errorDesc: String = (
                    String(data: errorAndData.data ?? Data(), encoding: .utf8)
                    ?? errorAndData.localizedDescription
                )
                serverStatus = "[\(Date.now)] \(endpoint) network error: " + errorDesc

                let errorMessage = TemporaryChatMessage(
                    role: "\(callerName) \(endpoint) network error: \(errorAndData.localizedDescription)",
                    content: responseInEdit?.content ?? errorDesc,
                    createdAt: Date.now
                )
                sequence.messages.append(.temporary(errorMessage, .clientError))
            }
        }
    }

    private func flushResponseBuffer() {
        guard self.responseInEdit != nil else { return }
        guard !bufferedResponseContent.isEmpty else { return }

        self.responseInEdit!.content!.append(bufferedResponseContent)
        bufferedResponseContent = ""
        bufferedResponseLastFlush = Date.now
    }

    private func _parseJSONChunk(_ jsonData: JSON) {
        let timeSinceFlush = Date.now.timeIntervalSince(bufferedResponseLastFlush)
        let flushBufferedUpdates = timeSinceFlush * 1000 > Double(settings.defaults.responseBufferFlushFrequencyMsec)

        if let status = jsonData["status"].string {
            //print("[TRACE] new server status: \(status)")
            bufferedServerStatus = status

            if flushBufferedUpdates {
                serverStatus = bufferedServerStatus
            }
        }

        let messageFragment = jsonData["message"]["content"].stringValue
        bufferedResponseContent.append(messageFragment)

        if flushBufferedUpdates {
            if !bufferedResponseContent.isEmpty {
                //print("[TRACE] Flushing response buffer: \(bufferedResponseContent.count) chars after \(String(format: "%.3f", timeSinceFlush)) seconds")
            }

            if self.responseInEdit == nil {
                print("[WARNING] responseInEdit is already nil, did we pre-parse packets too early?")
                print("- current buffer content: \"\(bufferedResponseContent)\"")
                print("- received chunk: \(jsonData)")

                // DEBUG: There's a race condition somewhere that lets you continue submitting while still receiving.
                // For now, just duplicate the code from receiveHandler().
                //
                // NB All this state-mungeing is okay for now because we refresh the entire sequenceDetails on end of inference.
                //
                promptInEdit = ""
                receivedDone = 0
                receivedError = 0
                responseInEdit = TemporaryChatMessage(
                    role: "erroneous response (continued after \"done\")",
                    content: submittedAssistantResponseSeed ?? "",
                    createdAt: Date.now
                )
                submittedAssistantResponseSeed = nil
                submitting = false
            }

            flushResponseBuffer()
        }

        if let promptWithTemplating = jsonData["prompt_with_templating"].string {
            let templated = TemporaryChatMessage(
                role: "user prompt (with model template + RAG context)",
                content: promptWithTemplating,
                // Don't use the current time, because this comes at the end of inference,
                // so the date provided/used is usually far later than responseInEdit, which is marked by its own start time.
                createdAt: responseInEdit?.createdAt ?? Date.distantPast
            )

            sequence.messages.append(.temporary(templated, .serverInfo))

            // If we get this end-of-prompt field, flush the response content buffer.
            // (We're probably done rendering, just autonaming left.)
            flushResponseBuffer()
        }

        if jsonData["done"].boolValue {
            receivedDone += 1
            flushResponseBuffer()
        }

        if let errorDesc = jsonData["error"].string {
            serverStatus = "[\(Date.now)] server error: " + errorDesc
            receivedError += 1

            if !(responseInEdit?.content ?? "").isEmpty {
                let savedResponse = TemporaryChatMessage(
                    role: "partial assistant response",
                    content: responseInEdit?.content!,
                    createdAt: responseInEdit?.createdAt ?? Date.now
                )
                sequence.messages.append(.temporary(savedResponse, .serverInfo))
            }

            // TODO: This gets printed out of order, should appear at the bottom, after responseInEdit
            let errorMessage = TemporaryChatMessage(
                role: "server-reported error",
                content: errorDesc,
                createdAt: Date.now
            )
            sequence.messages.append(.temporary(errorMessage, .serverError))
        }

        // NB This block is what actually marks the Sequence as "done" and gives us whatever updates we might need.
        if let replacementSequenceId: ChatSequenceServerID = jsonData["new_sequence_id"].int {
            flushResponseBuffer()
            let originalSequenceId = self.sequence.serverId

            // Set the old sequence as non-leaf
            let nonLeafSequence = self.sequence.replaceIsLeaf(false)
            print("[TRACE] receiveHandler calling updateSequenceOffline: ChatSequence#\(originalSequenceId).isLeafSequence = false")
            self.chatService.updateSequenceOffline(originalSequenceId, withReplacement: nonLeafSequence)

            // And then tell everyone to point to the new sequence
            let updatedSequence = self.sequence.replaceServerId(replacementSequenceId)
            print("[TRACE] receiveHandler calling updateSequenceOffline: ChatSequence#\(originalSequenceId) => \(replacementSequenceId)")
            self.chatService.updateSequenceOffline(originalSequenceId, withReplacement: updatedSequence)
        }

        if let newMessageId: ChatMessageServerID = jsonData["new_message_id"].int {
            flushResponseBuffer()
            if responseInEdit != nil {
                responseInEdit!.content = (responseInEdit?.content ?? "")
                responseInEdit!.content!.append(bufferedResponseContent)

                let storedMessage = ChatMessage(
                    serverId: newMessageId,
                    hostSequenceId: sequence.serverId,
                    role: responseInEdit!.role ?? "[unknown]",
                    content: responseInEdit!.content!,
                    createdAt: responseInEdit!.createdAt
                )

                sequence.messages.append(.stored(storedMessage))
                responseInEdit = nil

                if receivedError > 0 {
                    // TODO: Remove this once we get error messages to show up at the bottom of the list.
                    // For now, this is an indication that the user should check above for errors.
                    sequence.messages.append(.temporary(
                        TemporaryChatMessage(
                            role: "server reported \(receivedError) errors",
                            createdAt: Date.now
                        ), .clientError))
                }
            }
        }

        let autoname: String = jsonData["autoname"].stringValue
        if !autoname.isEmpty && autoname != sequence.humanDesc {
            // If this is the first time we're getting a name, pin the title at the top (non persistent setting)
            settings.pinChatSequenceDesc = settings.pinChatSequenceDesc || (sequence.humanDesc ?? "").isEmpty

            let renamedSequence = sequence.replaceHumanDesc(desc: autoname)
            self.chatService.updateSequence(withSameId: renamedSequence)
        }
    }

    private func receiveHandler(
        caller callerName: String,
        endpoint: String
    ) -> ((Data) -> Void) {
        return { [self] newData in
            // On first data received, end "submitting" phase
            if submitting {
                promptInEdit = ""

                receivedDone = 0
                receivedError = 0
                responseInEdit = TemporaryChatMessage(
                    role: "assistant",
                    content: submittedAssistantResponseSeed ?? "",
                    createdAt: Date.now
                )

                submittedAssistantResponseSeed = nil

                // NB Don't live-update this; any direct SwiftUI updates from here will be very slow.
                // This is possibly because status bar rendering is implemented wrong, but not worth investigating.
                serverStatus = "\(endpoint): awaiting response"

                submitting = false
            }

            //print("[TRACE] OneSequenceViewModel.receiveHandler: \(String(data: newData, encoding: .utf8) ?? "[couldn't decode \(newData.count) bytes]")")

            // First, check if we have remnants of a prior chunk to process.
            var combinedData: Data = (incompleteResponseData ?? Data())
            combinedData.append(newData)

            if incompleteResponseData != nil && !incompleteResponseData!.isEmpty {
                print("[TRACE] OneSequenceViewModel.receiveHandler: rollover of \(incompleteResponseData!.count) bytes incompleteResponseData")
                incompleteResponseData = nil
            }

            while true {
                if combinedData.isEmpty {
                    break
                }

                // If we have newlines, parse up to it, and then continue iteration
                if let end: Int = combinedData.firstIndex(where: { $0 == "\n".utf8.first }) {
                    //print("[TRACE] OneSequenceViewModel.receiveHandler: Parsing up to byte \(end + 1) of \(combinedData.endIndex) bytes remaining")
                    let dataChunk: Data = combinedData.prefix(through: end)
                    let jsonChunk: JSON = JSON(dataChunk)

                    if !jsonChunk.isEmpty {
                        //print("[TRACE] OneSequenceViewModel.receiveHandler: Successful partial parse: \(jsonChunk)")
                        _parseJSONChunk(jsonChunk)
                        combinedData = combinedData.suffix(from: end + 1)
                        continue
                    }
                    else {
                        if dataChunk == "\n".data(using: .utf8) {
                        }
                        else {
                            // Reaching here means we couldn't parse a newline-delimited chunk.
                            // Need to fix it ourselves; newlines shouldn't be in encoded JSON
                            print(
                                "[ERROR] OneSequenceViewModel.receiveHandler: Failed to parse, dropping "
                                + "\(dataChunk.count) bytes: \"\(String(data: dataChunk, encoding: .utf8) ?? "[invalid]")\"")
                        }

                        combinedData = combinedData.suffix(from: end + 1)
                        continue
                    }
                }
                // Otherwise, try parsing everything all together
                else {
                    print("[TRACE] OneSequenceViewModel.receiveHandler: Parsing all of \(combinedData.count) bytes remaining")
                    let jsonChunk: JSON = JSON(combinedData)

                    if !jsonChunk.isEmpty {
                        // print("[TRACE] OneSequenceViewModel.receiveHandler: Successful parse")
                        _parseJSONChunk(jsonChunk)
                        incompleteResponseData = nil
                        combinedData = Data()
                        break
                    }
                    else {
                        print("[WARNING] Failed parse, rolling over remaining \(combinedData.count) bytes")
                        incompleteResponseData = combinedData
                        combinedData = Data()
                        break
                    }
                }
            }
        }
    }

    private func save() async throws -> ChatSequence? {
        let messageId: ChatMessageServerID? = try await chatService.constructChatMessage(from: TemporaryChatMessage(
            role: "user",
            content: promptInEdit,
            createdAt: Date.now
        ))
        guard messageId != nil else {
            print("[ERROR] Couldn't construct ChatMessage from text: \(promptInEdit)")
            stopSubmitAndReceive()

            return nil
        }

        let replacementSequenceId: ChatSequenceServerID? = try await chatService.appendMessage(sequence: self.sequence, messageId: messageId!)
        guard replacementSequenceId != nil else {
            print("[ERROR] Couldn't save new message to sequence \(self.sequence.serverId)")
            stopSubmitAndReceive()

            return nil
        }

        // Manually (re)construct server data, rather than fetching the same data back.
        var replacementMessages = self.sequence.messages
        replacementMessages.append(.stored(ChatMessage(
            serverId: messageId!,
            hostSequenceId: replacementSequenceId!,
            role: "user",
            content: self.promptInEdit,
            createdAt: Date.now)))

        var replacementParents: [ChatSequenceServerID]? = nil
        if self.sequence.parentSequences != nil {
            replacementParents = self.sequence.parentSequences!
            replacementParents!.insert(replacementSequenceId!, at: 0)
        }

        let replacementSequence: ChatSequence = ChatSequence(
            serverId: replacementSequenceId!,
            humanDesc: self.sequence.humanDesc,
            userPinned: self.sequence.userPinned,
            generatedAt: Date.now,
            messages: replacementMessages,
            inferenceModelId: self.sequence.inferenceModelId,
            isLeafSequence: true,
            parentSequences: replacementParents
        )

        return replacementSequence
    }

    func requestSave() {
        print("[INFO] OneSequenceViewModel.requestSave()")

        guard !self.promptInEdit.isEmpty else { return }
        guard !submitting else {
            print("[ERROR] OneSequenceViewModel.requestSave() during another submission")
            return
        }
        guard !receiving else {
            print("[ERROR] OneSequenceViewModel.requestSave() while receiving response")
            return
        }

        self.submitting = true
        self.serverStatus = "/sequences/\(self.sequence.serverId): appending follow-up message"

        Task {
            let appendResult = try? await self.save()
            guard appendResult != nil else { return }

            DispatchQueue.main.async {
                let originalSequenceId = self.sequence.serverId

                // Set the old sequence as non-leaf
                let nonLeafSequence = self.sequence.replaceIsLeaf(false)
                print("[TRACE] requestSave calling updateSequenceOffline: ChatSequence#\(originalSequenceId).isLeafSequence = false")
                self.chatService.updateSequenceOffline(originalSequenceId, withReplacement: nonLeafSequence)

                // And then tell everyone to point to the new sequence
                print("[TRACE] requestSave calling updateSequenceOffline: ChatSequence#\(originalSequenceId) => \(appendResult!.serverId)")
                self.chatService.updateSequenceOffline(originalSequenceId, withReplacement: appendResult!)

                self.promptInEdit = ""
                self.stopSubmitAndReceive()
            }
        }
    }

    func requestContinue(
        model continuationModelId: FoundationModelRecordID? = nil,
        withRetrieval: Bool = false
    ) -> Self {
        print("[INFO] OneSequenceViewModel.requestContinue(\(continuationModelId), withRetrieval: \(withRetrieval))")
        if settings.stayAwakeDuringInference {
            _ = stayAwake.createAssertion(reason: "brokegen OneSequenceViewModel.requestContinue() for ChatSequence#\(self.sequence.serverId)")
        }

        guard !submitting else {
            print("[ERROR] OneSequenceViewModel.requestContinue(withRetrieval: \(withRetrieval)) during another submission")
            return self
        }
        guard !receiving else {
            print("[ERROR] OneSequenceViewModel.requestContinue(withRetrieval: \(withRetrieval)) while receiving response")
            return self
        }

        self.submitting = true
        self.serverStatus = "/sequences/\(self.sequence.serverId)/continue: submitting request"

        submittedAssistantResponseSeed = settings.seedAssistantResponse

        Task {
            receivingStreamer = await chatService.sequenceContinue(
                ContinueParameters(
                    continuationModelId: continuationModelId,
                    fallbackModelId: appSettings.fallbackInferenceModel?.serverId,
                    inferenceOptions: settings.inferenceOptions,
                    overrideModelTemplate: settings.overrideModelTemplate,
                    overrideSystemPrompt: settings.overrideSystemPrompt,
                    seedAssistantResponse: settings.seedAssistantResponse,
                    retrievalPolicy: withRetrieval ? settings.retrievalPolicy : nil,
                    retrievalSearchArgs: withRetrieval ? settings.retrievalSearchArgs : nil,
                    preferredEmbeddingModel: withRetrieval ? appSettings.preferredEmbeddingModel?.serverId : nil,
                    autonamingPolicy: settings.autonamingPolicy.rawValue,
                    preferredAutonamingModel: appSettings.preferredAutonamingModel?.serverId,
                    sequenceId: sequence.serverId
                )
            )
                .sink(receiveCompletion: completionHandler(
                    caller: "ChatSyncService.sequenceContinue",
                    endpoint: "/sequences/\(sequence.serverId)/continue"
                ), receiveValue: receiveHandler(
                    caller: "OneSequenceViewModel.requestContinue(withRetrieval: \(withRetrieval))",
                    endpoint: "/sequences/\(sequence.serverId)/continue"
                ))
        }

        return self
    }

    func requestExtend(
        model continuationModelId: FoundationModelRecordID? = nil,
        withRetrieval: Bool = false
    ) {
        print("[INFO] OneSequenceViewModel.requestExtend(model: \(continuationModelId), withRetrieval: \(withRetrieval))")
        if settings.stayAwakeDuringInference {
            _ = stayAwake.createAssertion(reason: "brokegen OneSequenceViewModel.requestExtend() for ChatSequence#\(self.sequence.serverId)")
        }

        guard !self.promptInEdit.isEmpty else { return }
        guard !submitting else {
            print("[ERROR] OneSequenceViewModel.requestExtend(withRetrieval: \(withRetrieval)) during another submission")
            return
        }
        guard !receiving else {
            print("[ERROR] OneSequenceViewModel.requestExtend(withRetrieval: \(withRetrieval)) while receiving response")
            return
        }

        self.submitting = true
        self.serverStatus = "/sequences/\(self.sequence.serverId): appending follow-up message"

        submittedAssistantResponseSeed = settings.seedAssistantResponse

        Task {
            let appendResult = try? await self.save()
            guard appendResult != nil else { return }

            DispatchQueue.main.sync {
                let originalSequenceId = self.sequence.serverId
                print("[TRACE] requestExtend calling updateSequenceOffline: ChatSequence#\(originalSequenceId) => \(appendResult!.serverId)")
                self.chatService.updateSequenceOffline(originalSequenceId, withReplacement: appendResult!)

                self.serverStatus = "/sequences/\(self.sequence.serverId)/continue: submitting request"
            }

            receivingStreamer = await chatService.sequenceContinue(
                ContinueParameters(
                    continuationModelId: continuationModelId,
                    fallbackModelId: appSettings.fallbackInferenceModel?.serverId,
                    inferenceOptions: settings.inferenceOptions,
                    overrideModelTemplate: settings.overrideModelTemplate,
                    overrideSystemPrompt: settings.overrideSystemPrompt,
                    seedAssistantResponse: settings.seedAssistantResponse,
                    retrievalPolicy: withRetrieval ? settings.retrievalPolicy : nil,
                    retrievalSearchArgs: withRetrieval ? settings.retrievalSearchArgs : nil,
                    preferredEmbeddingModel: withRetrieval ? appSettings.preferredEmbeddingModel?.serverId : nil,
                    autonamingPolicy: settings.autonamingPolicy.rawValue,
                    preferredAutonamingModel: appSettings.preferredAutonamingModel?.serverId,
                    sequenceId: sequence.serverId
                )
            )
                .sink(receiveCompletion: completionHandler(
                    caller: "ChatSyncService.sequenceContinue",
                    endpoint: "/sequences/\(sequence.serverId)/continue"
                ), receiveValue: receiveHandler(
                    caller: "OneSequenceViewModel.requestExtend(withRetrieval: \(withRetrieval))",
                    endpoint: "/sequences/\(sequence.serverId)/continue"
                ))
        }

        return
    }

    func stopSubmitAndReceive(userRequested: Bool = false) {
        receivingStreamer?.cancel()
        receivingStreamer = nil

        _ = stayAwake.destroyAssertion()
        submittedAssistantResponseSeed = nil

        if submitting {
            serverStatus = nil
            submitting = false
        }

        if !bufferedResponseContent.isEmpty {
            responseInEdit?.content?.append(bufferedResponseContent)
            bufferedResponseContent = ""
        }
        if responseInEdit != nil {
            if responseInEdit!.content == settings.seedAssistantResponse {
                // We haven't actually received a response yet, so don't bother committing the submitted message.
            }
            else if !(responseInEdit!.content ?? "").isEmpty {
                if receivedDone != 1 {
                    responseInEdit!.role = "partial assistant response"
                }
                sequence.messages.append(.temporary(responseInEdit!, .serverInfo))
            }

            serverStatus = nil
            responseInEdit = nil
        }

        receivedDone = 0
        receivedError = 0
        incompleteResponseData = nil
    }
}

extension OneSequenceViewModel: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(sequence)
        hasher.combine(promptInEdit)
        hasher.combine(responseInEdit)
    }
}

extension OneSequenceViewModel: Equatable {
    static func == (lhs: OneSequenceViewModel, rhs: OneSequenceViewModel) -> Bool {
        if lhs.sequence != rhs.sequence {
            return false
        }

        if lhs.promptInEdit != rhs.promptInEdit {
            return false
        }

        if lhs.responseInEdit != rhs.responseInEdit {
            return false
        }

        return true
    }
}
