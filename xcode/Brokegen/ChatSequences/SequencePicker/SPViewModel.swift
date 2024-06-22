import Combine
import SwiftData

/// TODO: Use this to implement context menus for common ChatSequence operations
@Observable
class SPViewModel: ObservableObject {
    @ObservationIgnored let chatSettingsService: CSCSettingsService
    var requestedBlankOSV: Bool = false

    init(
        chatSettingsService: CSCSettingsService
    ) {
        self.chatSettingsService = chatSettingsService
    }
}
