import UIKit
import Photos
import PhotosUI
import CoreServices
import SDWebImage
import MixinServices

class StickerManagerViewController: UICollectionViewController {
    
    private var stickers = [StickerItem]()
    private var isDeleteStickers = false
    private var pickerContentOffset = CGPoint.zero
    private var gifTypeIdentifier: String {
        if #available(iOS 14.0, *) {
            return UTType.gif.identifier
        } else {
            return kUTTypeGIF as String
        }
    }
    
    private lazy var itemSize: CGSize = {
        let minWidth: CGFloat = UIScreen.main.bounds.width > 400 ? 120 : 100
        let rowCount = floor(UIScreen.main.bounds.size.width / minWidth)
        let itemWidth = (UIScreen.main.bounds.size.width - (rowCount + 1) * 8) / rowCount
        return CGSize(width: itemWidth, height: itemWidth)
    }()
    
    class func instance() -> UIViewController {
        let vc = R.storyboard.chat.sticker_manager()!
        return ContainerViewController.instance(viewController: vc, title: R.string.localizable.my_Stickers())
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        fetchStickers()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(fetchStickers),
                                               name: StickerDAO.favoriteStickersDidChangeNotification,
                                               object: nil)
    }
    
    @objc private func fetchStickers() {
        DispatchQueue.global().async { [weak self] in
            let stickers = StickerDAO.shared.getFavoriteStickers()
            DispatchQueue.main.async {
                self?.stickers = stickers
                self?.collectionView?.reloadData()
                self?.container?.rightButton.isEnabled = stickers.count > 0
            }
        }
    }
    
}

extension StickerManagerViewController: ContainerViewControllerDelegate {
    
    func prepareBar(rightButton: StateResponsiveButton) {
        rightButton.isEnabled = true
        rightButton.setTitleColor(.systemTint, for: .normal)
    }
    
    func barRightButtonTappedAction() {
        if isDeleteStickers {
            guard
                !(container?.rightButton.isBusy ?? true),
                let selectionCells = collectionView?.indexPathsForSelectedItems, selectionCells.count > 0
            else {
                container?.rightButton.setTitle(R.string.localizable.select(), for: .normal)
                isDeleteStickers = false
                collectionView?.allowsMultipleSelection = false
                collectionView?.reloadData()
                return
            }
            container?.rightButton.isBusy = true
            
            let stickerIds: [String] = selectionCells.compactMap { (indexPath) -> String? in
                guard indexPath.row < stickers.count else {
                    return nil
                }
                return stickers[indexPath.row].stickerId
            }
            
            StickerAPI.removeSticker(stickerIds: stickerIds, completion: { [weak self] (result) in
                guard let weakSelf = self else {
                    return
                }
                weakSelf.container?.rightButton.isBusy = false
                switch result {
                case .success:
                    DispatchQueue.global().async {
                        if let album = AlbumDAO.shared.getPersonalAlbum() {
                            StickerRelationshipDAO.shared.removeStickers(albumId: album.albumId, stickerIds: stickerIds)
                        }
                        
                        DispatchQueue.main.async {
                            guard let weakSelf = self else {
                                return
                            }
                            weakSelf.container?.rightButton.setTitle(R.string.localizable.select(), for: .normal)
                            weakSelf.isDeleteStickers = !weakSelf.isDeleteStickers
                            weakSelf.collectionView?.allowsMultipleSelection = false
                            weakSelf.fetchStickers()
                        }
                    }
                case let .failure(error):
                    showAutoHiddenHud(style: .error, text: error.localizedDescription)
                }
            })
        } else {
            container?.rightButton.setTitle(R.string.localizable.remove(), for: .normal)
            isDeleteStickers = true
            collectionView?.allowsMultipleSelection = true
            collectionView?.reloadData()
        }
    }
    
    func textBarRightButton() -> String? {
        R.string.localizable.select()
    }
    
}

extension StickerManagerViewController: UICollectionViewDelegateFlowLayout {
    
    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return isDeleteStickers ? stickers.count : stickers.count + 1
    }
    
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        return itemSize
    }
    
    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: R.reuseIdentifier.favorite_sticker, for: indexPath)!
        if isDeleteStickers {
            cell.render(sticker: stickers[indexPath.row], isDeleteStickers: isDeleteStickers)
        } else {
            if indexPath.row == 0 {
                cell.selectionImageView.isHidden = true
                cell.stickerView.load(image: R.image.ic_sticker_add(), contentMode: .center)
            } else {
                cell.render(sticker: stickers[indexPath.row-1], isDeleteStickers: isDeleteStickers)
            }
        }
        return cell
    }
    
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !isDeleteStickers, indexPath.row == 0 else {
            return
        }
        handleAddStickerAction()
    }
    
}

// MARK: - PhotoAssetPickerDelegate
extension StickerManagerViewController: PhotoAssetPickerDelegate {
    
    func pickerController(_ picker: PickerViewController, contentOffset: CGPoint, didFinishPickingMediaWithAsset asset: PHAsset) {
        pickerContentOffset = contentOffset
        let vc = StickerAddViewController.instance(source: .asset(asset))
        navigationController?.pushViewController(vc, animated: true)
    }
    
}

// MARK: - PHPickerViewControllerDelegate
@available(iOS 14, *)
extension StickerManagerViewController: PHPickerViewControllerDelegate {
    
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true) {
            guard let provider = results.first?.itemProvider else {
                return
            }
            self.load(itemProvider: provider)
        }
    }
    
}

// MARK: - Private works
extension StickerManagerViewController {
    
    private func handleAddStickerAction() {
        let status: PHAuthorizationStatus
        if #available(iOS 14.0, *) {
            status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        } else {
            status = PHPhotoLibrary.authorizationStatus()
        }
        handlePhotoAuthorizationStatus(status)
    }
    
    private func handlePhotoAuthorizationStatus(_ status: PHAuthorizationStatus) {
        switch status {
        case .limited:
            DispatchQueue.main.async(execute: showAuthorizationLimitedAlert)
        case .authorized:
            DispatchQueue.main.async {
                let picker = PhotoAssetPickerNavigationController.instance(pickerDelegate: self, showImageOnly: true, scrollToOffset: self.pickerContentOffset)
                self.present(picker, animated: true, completion: nil)
            }
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(handlePhotoAuthorizationStatus)
        case .denied, .restricted:
            DispatchQueue.main.async {
                self.alertSettings(R.string.localizable.permission_denied_photo_library())
            }
        @unknown default:
            DispatchQueue.main.async {
                self.alertSettings(R.string.localizable.permission_denied_photo_library())
            }
        }
    }
    
    private func showAuthorizationLimitedAlert() {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        if #available(iOS 14, *) {
            sheet.addAction(UIAlertAction(title: R.string.localizable.pick_from_Library(), style: .default, handler: { _ in
                var config = PHPickerConfiguration(photoLibrary: .shared())
                config.preferredAssetRepresentationMode = .current
                config.selectionLimit = 1
                config.filter = .images
                let picker = PHPickerViewController(configuration: config)
                picker.delegate = self
                self.present(picker, animated: true, completion: nil)
            }))
        }
        sheet.addAction(UIAlertAction(title: R.string.localizable.change_Settings(), style: .default, handler: { _ in
            UIApplication.openAppSettings()
        }))
        sheet.addAction(UIAlertAction(title: R.string.localizable.cancel(), style: .cancel, handler: nil))
        present(sheet, animated: true, completion: nil)
    }
    
    private func load(itemProvider: NSItemProvider) {
        let hud = Hud()
        hud.show(style: .busy, text: "", on: AppDelegate.current.mainWindow)
        let hideHud = {
            DispatchQueue.main.async {
                hud.hide()
            }
        }
        let handleError = { (error: Error?) in
            if let error = error {
                reporter.report(error: error)
            }
            DispatchQueue.main.async {
                showAutoHiddenHud(style: .error, text: R.string.localizable.operation_failed())
            }
        }
        if itemProvider.hasItemConformingToTypeIdentifier(gifTypeIdentifier) {
            itemProvider.loadFileRepresentation(forTypeIdentifier: gifTypeIdentifier) { [weak self] (source, error) in
                hideHud()
                guard
                    let source = source,
                    let image = SDAnimatedImage(contentsOfFile: source.path)
                else {
                    handleError(error)
                    return
                }
                DispatchQueue.main.async {
                    guard let self = self else {
                        return
                    }
                    let vc = StickerAddViewController.instance(source: .image(image))
                    self.navigationController?.pushViewController(vc, animated: true)
                }
            }
        } else if itemProvider.canLoadObject(ofClass: UIImage.self) {
            itemProvider.loadObject(ofClass: UIImage.self) { [weak self] (rawImage, error) in
                hideHud()
                guard
                    let rawImage = rawImage as? UIImage,
                    let image = ImageUploadSanitizer.sanitizedImage(from: rawImage).image
                else {
                    handleError(error)
                    return
                }
                DispatchQueue.main.async {
                    guard let self = self else {
                        return
                    }
                    let vc = StickerAddViewController.instance(source: .image(image))
                    self.navigationController?.pushViewController(vc, animated: true)
                }
            }
        }
    }
    
}
