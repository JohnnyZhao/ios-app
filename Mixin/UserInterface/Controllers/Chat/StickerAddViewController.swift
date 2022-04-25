import CoreServices
import UIKit
import Photos
import SDWebImage
import MixinServices

class StickerAddViewController: UIViewController {
    
    enum Source {
        case message(MessageItem)
        case asset(PHAsset)
        case image(UIImage)
    }
    
    @IBOutlet weak var previewImageView: SDAnimatedImageView!
    
    private var source: Source!
    
    class func instance(source: Source) -> UIViewController {
        let vc = R.storyboard.chat.sticker_add()!
        vc.source = source
        return ContainerViewController.instance(viewController: vc, title: R.string.localizable.add_Sticker())
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        switch source! {
        case .message(let item):
            let updateRightButton: SDExternalCompletionBlock = { [weak self] (image, error, _, _) in
                self?.container?.rightButton.isEnabled = image != nil
            }
            if let assetUrl = item.assetUrl {
                let context = [SDWebImageContextOption.animatedImageClass: SDAnimatedImage.self]
                previewImageView.sd_setImage(with: URL(string: assetUrl),
                                             placeholderImage: nil,
                                             context: context,
                                             progress: nil,
                                             completed: updateRightButton)
            } else if let mediaUrl = item.mediaUrl {
                let url = AttachmentContainer.url(for: .photos, filename: mediaUrl)
                previewImageView.sd_setImage(with: url,
                                             placeholderImage: nil,
                                             context: localImageContext,
                                             progress: nil,
                                             completed: updateRightButton)
            } else {
                // container's right button will keep disabled if no image is loaded
            }
        case .asset(let asset):
            let manager = PHImageManager.default()
            let options = PHImageRequestOptions()
            options.version = .current
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            if asset.playbackStyle == .imageAnimated {
                manager.requestImageDataAndOrientation(for: asset, options: options) { [weak self] (data, _, _, _) in
                    guard let self = self, let data = data, let image = SDAnimatedImage(data: data) else {
                        return
                    }
                    self.previewImageView.image = image
                    self.container?.rightButton.isEnabled = true
                }
            } else {
                manager.requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .default, options: options) { [weak self] (image, _) in
                    guard let self = self, let image = image else {
                        return
                    }
                    self.previewImageView.image = image
                    self.container?.rightButton.isEnabled = true
                }
            }
        case .image(let image):
            previewImageView.image = image
            container?.rightButton.isEnabled = true
        }
    }
    
}

extension StickerAddViewController: ContainerViewControllerDelegate {
    
    func prepareBar(rightButton: StateResponsiveButton) {
        rightButton.setTitleColor(.systemTint, for: .normal)
        rightButton.isEnabled = false
    }
    
    func barRightButtonTappedAction() {
        guard let rightButton = container?.rightButton, !rightButton.isBusy else {
            return
        }
        rightButton.isBusy = true
        if let image = previewImageView.image as? SDAnimatedImage, image.animatedImageFrameCount > 1, let data = image.animatedImageData {
            if isValid(animatedImageData: data) {
                performAddition(data: data)
            } else {
                showMalformedAlert()
            }
        } else if let image = previewImageView.image {
            scaleImageAndPerformAdditionIfValid(image: image)
        } else {
            showFailureAlert()
            assertionFailure("This is not expected to happen since right button should be disabled before any image is presented")
        }
    }
    
    func textBarRightButton() -> String? {
        R.string.localizable.save()
    }
    
}

extension StickerAddViewController {
    
    private func showMalformedAlert() {
        container?.rightButton.isBusy = false
        let alert = UIAlertController(title: R.string.localizable.sticker_add_invalid_size(), message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: R.string.localizable.oK(), style: .default, handler: nil))
        present(alert, animated: true, completion: nil)
    }
    
    private func showFailureAlert() {
        container?.rightButton.isBusy = false
        showAutoHiddenHud(style: .error, text: R.string.localizable.operation_failed())
    }
    
    private func scaledSize(for size: CGSize) -> CGSize {
        let maxLength: CGFloat = 360
        let scale = CGFloat(size.width) / CGFloat(size.height)
        let width: CGFloat = size.width > size.height ? maxLength : maxLength * scale
        let height: CGFloat = size.width > size.height ? maxLength / scale : maxLength
        return CGSize(width: width, height: height)
    }
    
    private func scaleImageAndPerformAdditionIfValid(image: UIImage) {
        DispatchQueue.global().async { [weak self] in
            guard image.size.width > 0 && image.size.height > 0 else {
                DispatchQueue.main.async(execute: {
                    self?.showMalformedAlert()
                })
                return
            }
            guard let scaledSize = self?.scaledSize(for: image.size) else {
                return
            }
            let scaledImage = image.imageByScaling(to: scaledSize)
            guard let data = scaledImage?.jpegData(compressionQuality: JPEGCompressionQuality.medium) else {
                DispatchQueue.main.async(execute: {
                    self?.showFailureAlert()
                })
                return
            }
            self?.performAddition(data: data)
        }
    }
    
    private func isValid(animatedImageData data: Data) -> Bool {
        let sizeInKiloBytes = Double(data.count) / Double(bytesPerKiloByte)
        guard sizeInKiloBytes > 1 && sizeInKiloBytes < 800 else {
            return false
        }
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            return false
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let size: CGSize
        if let width = properties?[kCGImagePropertyPixelWidth] as? NSNumber, let height = properties?[kCGImagePropertyPixelHeight] as? NSNumber {
            size = CGSize(width: width.doubleValue, height: height.doubleValue)
        } else {
            size = SDAnimatedImage(data: data)?.size ?? .zero
        }
        return min(size.width, size.height) >= 64
            && max(size.width, size.height) <= 512
    }
    
    private func performAddition(data: Data) {
        let base64 = data.base64EncodedString()
        StickerAPI.addSticker(stickerBase64: base64, completion: { [weak self] (result) in
            switch result {
            case let .success(sticker):
                SDImageCache.persistentSticker.storeImageData(toDisk: data, forKey: sticker.assetUrl)
                DispatchQueue.global().async { [weak self] in
                    StickerDAO.shared.insertOrUpdateFavoriteSticker(sticker: sticker)
                    DispatchQueue.main.async {
                        showAutoHiddenHud(style: .notification, text: R.string.localizable.added())
                        self?.navigationController?.popViewController(animated: true)
                    }
                }
            case let .failure(error):
                self?.container?.rightButton.isBusy = false
                showAutoHiddenHud(style: .error, text: error.localizedDescription)
            }
        })
    }
    
}
