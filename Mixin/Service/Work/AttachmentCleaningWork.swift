import Foundation
import MixinServices

final class AttachmentCleaningWork: Work {
    
    private var finishedCategories: Set<AttachmentContainer.Category>
    
    convenience init() {
        self.init(finishedCategories: [])
    }
    
    private init(finishedCategories: Set<AttachmentContainer.Category>) {
        self.finishedCategories = finishedCategories
        super.init(id: "attachment_clean", state: .ready)
    }
    
    override func main() throws {
        guard -AppGroupUserDefaults.User.lastAttachmentCleanUpDate.timeIntervalSinceNow >= 7 * .oneDay else {
            return
        }
        let categories: [AttachmentContainer.Category] = [.photos, .audios, .files, .videos].filter { category in
            !finishedCategories.contains(category)
        }
        for category in categories {
            Logger.general.debug(category: "AttachmentCleaningWork", message: "Cleaning \(category)")
            let path = AttachmentContainer.url(for: category, filename: nil).path
            guard let onDiskFilenames = try? FileManager.default.contentsOfDirectory(atPath: path), onDiskFilenames.count > 0 else {
                continue
            }
            if category == .videos {
                let referencedFilenames = MessageDAO.shared
                    .getMediaUrls(categories: category.messageCategory)
                    .map({ NSString(string: $0).deletingPathExtension })
                for onDiskFilename in onDiskFilenames where !referencedFilenames.contains(where: { onDiskFilename.contains($0) }) {
                    let url = AttachmentContainer.url(for: .videos, filename: onDiskFilename)
                    try? FileManager.default.removeItem(at: url)
                }
            } else {
                let referencedFilenames = Set(MessageDAO.shared.getMediaUrls(categories: category.messageCategory))
                for onDiskFilename in onDiskFilenames where !referencedFilenames.contains(onDiskFilename) {
                    let url = AttachmentContainer.url(for: category, filename: onDiskFilename)
                    try? FileManager.default.removeItem(at: url)
                }
            }
            finishedCategories.insert(category)
            updatePersistedContext()
            Logger.general.debug(category: "AttachmentCleaningWork", message: "\(category) cleaned up")
        }
        AppGroupUserDefaults.User.lastAttachmentCleanUpDate = Date()
    }
    
}

extension AttachmentCleaningWork: PersistableWork {
    
    static let typeIdentifier: String = "attachment_clean"
    
    var context: Data? {
        try? JSONEncoder.default.encode(finishedCategories)
    }
    
    var priority: PersistedWork.Priority {
        .low
    }
    
    convenience init(id: String, context: Data?) throws {
        let categories: Set<AttachmentContainer.Category>
        if let context = context, let decoded = try? JSONDecoder.default.decode([AttachmentContainer.Category].self, from: context) {
            categories = Set(decoded)
        } else {
            categories = []
        }
        self.init(finishedCategories: categories)
    }
    
}
