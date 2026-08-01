import Foundation

struct MobileActivityWindow: Equatable {
    private(set) var oldestVisibleEntryId: String?
    let pageSize: Int

    init(entries: [MobileActivityEntry], pageSize: Int = 18) {
        self.pageSize = max(1, pageSize)
        oldestVisibleEntryId = entries.suffix(max(1, pageSize)).first?.id
    }

    mutating func synchronize(with entries: [MobileActivityEntry]) {
        guard !entries.isEmpty else {
            oldestVisibleEntryId = nil
            return
        }
        guard let oldestVisibleEntryId,
              entries.contains(where: { $0.id == oldestVisibleEntryId }) else {
            self.oldestVisibleEntryId = entries.suffix(pageSize).first?.id
            return
        }
    }

    mutating func showEarlier(in entries: [MobileActivityEntry]) {
        synchronize(with: entries)
        guard let oldestVisibleEntryId,
              let currentIndex = entries.firstIndex(where: { $0.id == oldestVisibleEntryId }) else { return }
        self.oldestVisibleEntryId = entries[max(0, currentIndex - pageSize)].id
    }

    func visibleEntries(in entries: [MobileActivityEntry]) -> ArraySlice<MobileActivityEntry> {
        guard let oldestVisibleEntryId,
              let startIndex = entries.firstIndex(where: { $0.id == oldestVisibleEntryId }) else {
            return entries.suffix(pageSize)
        }
        return entries[startIndex...]
    }

    func hiddenEntryCount(in entries: [MobileActivityEntry]) -> Int {
        guard let oldestVisibleEntryId,
              let startIndex = entries.firstIndex(where: { $0.id == oldestVisibleEntryId }) else {
            return max(0, entries.count - pageSize)
        }
        return startIndex
    }
}
