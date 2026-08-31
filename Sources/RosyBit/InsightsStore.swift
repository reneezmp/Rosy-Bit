import Combine
import Foundation

/// The captured requests, newest first.
///
/// In memory only, and deliberately so. On this machine the buffer holds
/// meeting transcripts and whatever else gets sent for summarising, so quitting
/// Rosy Bit has to be enough to erase them. Nothing here is ever written to
/// disk, and the bodies are redacted and truncated before they arrive.
///
/// Main thread only.
final class InsightsStore: ObservableObject {

    static let shared = InsightsStore()

    @Published private(set) var records: [RequestRecord] = []
    @Published private(set) var totalSeen = 0
    @Published var selectedRecordID: RequestRecord.ID?

    private init() {}

    func record(_ record: RequestRecord) {
        records.insert(record, at: 0)
        totalSeen += 1

        let capacity = Config.insightsCapacity
        if records.count > capacity {
            records.removeLast(records.count - capacity)
        }
    }

    func clear() {
        records.removeAll()
        totalSeen = 0
        selectedRecordID = nil
    }

    /// Select the newest request belonging to a chat response. Dictionary
    /// answers make two requests; newest-first therefore lands on the grounded
    /// prose request, while ordinary answers have exactly one match.
    @discardableResult
    func focus(onChatMessageID messageID: UUID) -> Bool {
        guard let record = records.first(where: { $0.chatMessageID == messageID }) else {
            return false
        }
        selectedRecordID = record.id
        return true
    }
}
