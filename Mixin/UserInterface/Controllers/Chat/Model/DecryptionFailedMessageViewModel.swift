import UIKit

class DecryptionFailedMessageViewModel: TextMessageViewModel {
    
    override var rawContent: String {
        return R.string.localizable.chat_waiting(message.userFullName ?? "") + R.string.localizable.learn_More()
    }
    
    override func linkRanges(from string: String) -> [Link.Range] {
        let location = (R.string.localizable.chat_waiting(message.userFullName ?? "") as NSString).length
        let length = (R.string.localizable.learn_More() as NSString).length
        let range = NSRange(location: location, length: length)
        return [Link.Range(range: range, url: .aboutEncryption)]
    }
    
}
