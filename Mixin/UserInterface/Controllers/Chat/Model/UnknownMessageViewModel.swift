import UIKit
import MixinServices

class UnknownMessageViewModel: TextMessageViewModel {
    
    override var rawContent: String {
        R.string.localizable.chat_not_support() + R.string.localizable.learn_More()
    }
    
    override init(message: MessageItem) {
        super.init(message: message)
        statusImage = nil
    }
    
    override func linkRanges(from string: String) -> [Link.Range] {
        let location = (R.string.localizable.chat_not_support() as NSString).length
        let length = (R.string.localizable.learn_More() as NSString).length
        let range = NSRange(location: location, length: length)
        return [Link.Range(range: range, url: .unknownCategory)]
    }
    
}
