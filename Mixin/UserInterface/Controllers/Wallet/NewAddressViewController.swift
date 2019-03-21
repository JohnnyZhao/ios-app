import UIKit

class NewAddressViewController: KeyboardBasedLayoutViewController {

    @IBOutlet weak var labelTextField: UITextField!
    @IBOutlet weak var addressTextView: PlaceholderTextView!
    @IBOutlet weak var accountNameButton: UIButton!
    @IBOutlet weak var saveButton: RoundedButton!
    @IBOutlet weak var assetView: AssetIconView!

    @IBOutlet weak var bottomConstraint: NSLayoutConstraint!
    
    private var asset: AssetItem!
    private var addressValue: String {
        return addressTextView.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    private var labelValue: String {
        return labelTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    private var successCallback: ((Address) -> Void)?
    private var address: Address?
    private var qrCodeScanningDestination: UIView?
    
    private weak var pinTipsView: PinTipsView?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        addressTextView.delegate = self
        addressTextView.textContainerInset = .zero
        addressTextView.textContainer.lineFragmentPadding = 0
        assetView.setIcon(asset: asset)
        if let address = address {
            if asset.isAccount {
                labelTextField.text = address.accountName
                addressTextView.text = address.accountTag
            } else {
                labelTextField.text = address.label
                addressTextView.text = address.publicKey
            }
            checkLabelAndAddressAction(self)
            view.layoutIfNeeded()
            textViewDidChange(addressTextView)
        }

        if asset.isAccount {
            labelTextField.placeholder = Localized.WALLET_ACCOUNT_NAME
            addressTextView.placeholder = Localized.WALLET_ACCOUNT_MEMO
            accountNameButton.isHidden = false
        }
        
        labelTextField.becomeFirstResponder()
    }
    
    override func layout(for keyboardFrame: CGRect) {
        let windowHeight = AppDelegate.current.window!.bounds.height
        bottomConstraint.constant = windowHeight - keyboardFrame.origin.y + 20
        view.layoutIfNeeded()
    }
    
    @IBAction func checkLabelAndAddressAction(_ sender: Any) {
        if let address = address {
            if asset.isAccount {
                saveButton.isEnabled = !addressValue.isEmpty && !labelValue.isEmpty && (labelValue != address.accountName || addressValue != address.accountTag)
            } else {
                saveButton.isEnabled = !addressValue.isEmpty && !labelValue.isEmpty && (labelValue != address.label || addressValue != address.publicKey)
            }
        } else {
            saveButton.isEnabled = !addressValue.isEmpty && !labelValue.isEmpty
        }
    }

    @IBAction func scanAddressAction(_ sender: Any) {
        let vc = CameraViewController.instance()
        vc.delegate = self
        navigationController?.pushViewController(vc, animated: true)
        qrCodeScanningDestination = addressTextView
    }

    @IBAction func scanAccountNameAction(_ sender: Any) {
        let vc = CameraViewController.instance()
        vc.delegate = self
        navigationController?.pushViewController(vc, animated: true)
        qrCodeScanningDestination = labelTextField
    }
    
    @IBAction func saveAction(_ sender: Any) {
        guard let actionButton = saveButton, !actionButton.isBusy else {
            return
        }
        guard !addressValue.isEmpty && !labelValue.isEmpty else {
            return
        }
        addressTextView.isUserInteractionEnabled = false
        labelTextField.isEnabled = false
        actionButton.isBusy = true
        pinTipsView = PinTipsView.instance(tips: Localized.WALLET_PASSWORD_ADDRESS_TIPS) { [weak self] (pin) in
            self?.saveAddressAction(pin: pin)
        }
        pinTipsView?.presentPopupControllerAnimated()
    }

    private func saveAddressAction(pin: String) {
        let assetId = asset.assetId
        let publicKey: String? = asset.isAccount ? nil : addressValue
        let label: String? = asset.isAccount ? nil : self.labelValue
        let accountName: String? = asset.isAccount ? self.labelValue : nil
        let accountTag: String? = asset.isAccount ? addressValue : nil
        let request = AddressRequest(assetId: assetId, publicKey: publicKey, label: label, pin: pin, accountName: accountName, accountTag: accountTag)
        WithdrawalAPI.shared.save(address: request) { [weak self](result) in
            switch result {
            case let .success(address):
                AddressDAO.shared.insertOrUpdateAddress(addresses: [address])
                if let weakSelf = self {
                    if weakSelf.address == nil {
                        WalletUserDefault.shared.lastWithdrawalAddress[assetId] = address.addressId
                    }
                    weakSelf.successCallback?(address)
                    showHud(style: .notification, text: Localized.TOAST_SAVED)
                    weakSelf.navigationController?.popViewController(animated: true)
                }
            case let .failure(error):
                showHud(style: .error, text: error.localizedDescription)
                self?.pinTipsView?.removeFromSuperview()
                self?.saveButton.isBusy = false
                self?.addressTextView.isUserInteractionEnabled = true
                self?.labelTextField.isEnabled = true
                self?.addressTextView.becomeFirstResponder()
            }
        }
    }
    
    class func instance(asset: AssetItem, address: Address? = nil, successCallback: ((Address) -> Void)? = nil) -> UIViewController {
        let vc = Storyboard.wallet.instantiateViewController(withIdentifier: "new_address") as! NewAddressViewController
        vc.asset = asset
        vc.successCallback = successCallback
        vc.address = address
        return ContainerViewController.instance(viewController: vc, title: address == nil ? Localized.ADDRESS_NEW_TITLE(symbol: asset.symbol) : Localized.ADDRESS_EDIT_TITLE(symbol: asset.symbol))
    }

}

extension NewAddressViewController: UITextViewDelegate {
    
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        return text != "\n"
    }
    
    func textViewDidChange(_ textView: UITextView) {
        checkLabelAndAddressAction(textView)
        view.layoutIfNeeded()
        let sizeToFit = CGSize(width: addressTextView.bounds.width,
                               height: UIView.layoutFittingExpandedSize.height)
        let contentSize = addressTextView.sizeThatFits(sizeToFit)
        addressTextView.isScrollEnabled = contentSize.height > addressTextView.frame.height
    }
    
}

extension NewAddressViewController: CameraViewControllerDelegate {
    
    func cameraViewController(_ controller: CameraViewController, shouldRecognizeString string: String) -> Bool {
        if qrCodeScanningDestination == labelTextField {
            labelTextField.text = string
            textViewDidChange(addressTextView)
            labelTextField.resignFirstResponder()
            addressTextView.becomeFirstResponder()
        } else if qrCodeScanningDestination == addressTextView {
            addressTextView.text = standarizedAddress(from: string) ?? string
            textViewDidChange(addressTextView)
        }
        qrCodeScanningDestination = nil
        navigationController?.popViewController(animated: true)
        return false
    }
    
}

extension NewAddressViewController {
    
    private func standarizedAddress(from str: String) -> String? {
        guard str.hasPrefix("iban:XE") || str.hasPrefix("IBAN:XE") else {
            return str
        }
        guard str.count >= 20 else {
            return nil
        }
        
        let endIndex = str.index(of: "?") ?? str.endIndex
        let accountIdentifier = str[str.index(str.startIndex, offsetBy: 9)..<endIndex]
        
        guard let address = accountIdentifier.lowercased().base36to16() else {
            return nil
        }
        return "0x\(address)"
    }
    
}

private extension String {
    
    private static let base36Alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"
    
    private static var base36AlphabetMap: [Character: Int] = {
        var reverseLookup = [Character: Int]()
        for characterIndex in 0..<String.base36Alphabet.count {
            let character = base36Alphabet[base36Alphabet.index(base36Alphabet.startIndex, offsetBy: characterIndex)]
            reverseLookup[character] = characterIndex
        }
        return reverseLookup
    }()
    
    func base36to16() -> String? {
        var bytes = [Int]()
        for character in self {
            guard var carry = String.base36AlphabetMap[character] else {
                return nil
            }
            
            for byteIndex in 0..<bytes.count {
                carry += bytes[byteIndex] * 36
                bytes[byteIndex] = carry & 0xff
                carry >>= 8
            }
            
            while carry > 0 {
                bytes.append(carry & 0xff)
                carry >>= 8
            }
        }
        return bytes.reversed().map { String(format: "%02hhx", $0) }.joined()
    }
    
}
