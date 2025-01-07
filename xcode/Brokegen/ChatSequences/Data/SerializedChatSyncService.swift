import Combine
import Foundation

class SerializedChatSyncService: DefaultChatSyncService {
    let semaphore: DispatchSemaphore

    init(
        _ serverBaseURL: String,
        configuration: URLSessionConfiguration,
        concurrentJobsLimit: Int = 1
    ) {
        self.semaphore = DispatchSemaphore(value: concurrentJobsLimit)
        super.init(serverBaseURL, configuration: configuration)
    }

    override func autonameBlocking(
        sequenceId: ChatSequenceServerID,
        preferredAutonamingModel: FoundationModelRecordID?
    ) async throws -> String? {
        /// TODO: This blocking state should be surfaced to the user
        print("[TRACE] Waiting for inference semaphore, autonameBlocking \(sequenceId)")

        semaphore.wait()
        print("[TRACE] SeralizedCSS got semaphore, starting autonameBlocking \(sequenceId)")

        let result = try? await super.autonameBlocking(sequenceId: sequenceId, preferredAutonamingModel: preferredAutonamingModel)

        semaphore.signal()

        return result
    }

    override public func sequenceContinue(
        _ params: ContinueParameters
    ) async -> AnyPublisher<Data, AFErrorAndData> {
        /// TODO: This blocking state should be surfaced to the user
        print("[TRACE] Waiting for inference semaphore, sequenceContinue \(params.sequenceId)")

        semaphore.wait()
        print("[TRACE] SeralizedCSS got semaphore, starting sequenceContinue \(params.sequenceId)")

        let continuer = await super.sequenceContinue(params)
        return continuer
            .handleEvents(receiveCompletion: { _ in
                self.semaphore.signal()
            }, receiveCancel: {
                self.semaphore.signal()
            })
            .eraseToAnyPublisher()
    }
}
