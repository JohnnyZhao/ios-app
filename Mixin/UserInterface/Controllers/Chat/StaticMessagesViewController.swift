import UIKit
import MixinServices

class StaticMessagesViewController: UIViewController {
    
    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var tableView: ConversationTableView!
        
    private let staticMessageId: String
    private let factory: ViewModelFactory
    private let alwaysUsesLegacyMenu = false
    
    private var viewModels: [String: [MessageViewModel]] = [:]
    private var dates: [String] = []
    private var indexPathToFlashAfterAnimationFinished: IndexPath?
    private var didPlayAudioMessage = false
    
    private lazy var audioManager: StaticAudioMessagePlayingManager = {
        let manager = StaticAudioMessagePlayingManager(staticMessageId: staticMessageId)
        manager.delegate = self
        return manager
    }()
    private lazy var backgroundButton: UIButton = {
        let button = UIButton()
        button.backgroundColor = .black.withAlphaComponent(0)
        button.addTarget(self, action: #selector(dismissAction(_:)), for: .touchUpInside)
        return button
    }()
    
    init(staticMessageId: String) {
        self.staticMessageId = staticMessageId
        self.factory = ViewModelFactory()
        let nib = R.nib.staticMessagesView
        super.init(nibName: nib.name, bundle: nib.bundle)
        factory.delegate = self
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        action == #selector(copySelectedMessage)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        updatePreferredContentSizeHeight()
        
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.dataSource = self
        if #available(iOS 13.0, *), !alwaysUsesLegacyMenu {
            tableView.delegate = self
        } else {
            tableView.delegate = self
            let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(showCopyMenu(_:)))
            tableView.addGestureRecognizer(recognizer)
        }
        
        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(tapAction(_:)))
        tapRecognizer.delegate = self
        tableView.addGestureRecognizer(tapRecognizer)
        
        let center = NotificationCenter.default
        center.addObserver(self,
                           selector: #selector(updateAttachmentProgress(_:)),
                           name: AttachmentLoadingJob.progressNotification,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(updateMessageMediaStatus(_:)),
                           name: MessageDAO.messageMediaStatusDidUpdateNotification,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(conversationDidChange(_:)),
                           name: MixinServices.conversationDidChangeNotification,
                           object: nil)
    }
    
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.preferredContentSizeCategory != previousTraitCollection?.preferredContentSizeCategory else {
            return
        }
        DispatchQueue.main.async {
            self.updatePreferredContentSizeHeight()
        }
    }
    
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        if view.safeAreaInsets.bottom < 20 {
            tableView.contentInset.bottom = 20 + AppDelegate.current.mainWindow.safeAreaInsets.top
        } else {
            tableView.contentInset.bottom = AppDelegate.current.mainWindow.safeAreaInsets.top
        }
    }
    
    @IBAction func dismissAction(_ sender: Any) {
        dismissAsChild(completion: nil)
    }
    
}

extension StaticMessagesViewController {
    
    func reloadData(items: [MessageItem], onMainQueue completion: (() -> Void)? = nil) {
        for item in items where item.category == MessageCategory.SIGNAL_STICKER.rawValue {
            if item.stickerId == nil {
                item.category = MessageCategory.SIGNAL_TEXT.rawValue
                item.content = R.string.localizable.notification_content_sticker()
            }
        }
        let layoutWidth = AppDelegate.current.mainWindow.bounds.width
        let (dates, viewModels) = factory.viewModels(with: items, fits: layoutWidth)
        DispatchQueue.main.async {
            completion?()
            self.dates = dates
            self.viewModels = viewModels
            self.tableView.reloadData()
        }
    }
    
    func dismissAsChild(completion: (() -> Void)?) {
        UIView.animate(withDuration: 0.3, animations: {
            self.view.frame.origin.y = self.backgroundButton.bounds.height
            self.backgroundButton.backgroundColor = .black.withAlphaComponent(0)
        }) { _ in
            self.willMove(toParent: nil)
            self.view.removeFromSuperview()
            self.removeFromParent()
            self.backgroundButton.removeFromSuperview()
            completion?()
        }
    }
    
    func presentAsChild(of parent: UIViewController) {
        loadViewIfNeeded()
        backgroundButton.frame = parent.view.bounds
        backgroundButton.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        parent.addChild(self)
        parent.view.addSubview(backgroundButton)
        didMove(toParent: parent)
        view.frame = CGRect(x: 0,
                            y: backgroundButton.bounds.height,
                            width: backgroundButton.bounds.width,
                            height: backgroundButton.bounds.height)
        view.autoresizingMask = .flexibleTopMargin
        backgroundButton.addSubview(view)
        UIView.animate(withDuration: 0.3) {
            self.view.frame.origin.y = self.backgroundButton.bounds.height - self.preferredContentSize.height
            self.backgroundButton.backgroundColor = .black.withAlphaComponent(0.3)
        }
    }
    
}

// MARK: - Actions
extension StaticMessagesViewController {
    
    @objc private func tapAction(_ recognizer: UIGestureRecognizer) {
        if UIMenuController.shared.isMenuVisible {
            UIMenuController.shared.setMenuVisible(false, animated: true)
            return
        }
        let tappedIndexPath = tableView.indexPathForRow(at: recognizer.location(in: tableView))
        let tappedViewModel: MessageViewModel? = {
            if let indexPath = tappedIndexPath {
                return viewModel(at: indexPath)
            } else {
                return nil
            }
        }()
        if let indexPath = tappedIndexPath,
           let viewModel = tappedViewModel,
           let cell = tableView.cellForRow(at: indexPath) as? MessageCell, cell.contentFrame.contains(recognizer.location(in: cell))
        {
            let message = viewModel.message
            let isImageOrVideo = message.category.hasSuffix("_IMAGE") || message.category.hasSuffix("_VIDEO")
            let mediaStatusIsReady = message.mediaStatus == MediaStatus.DONE.rawValue || message.mediaStatus == MediaStatus.READ.rawValue
            
            if let quoteMessageId = viewModel.message.quoteMessageId,
               !quoteMessageId.isEmpty,
               let quote = cell.quotedMessageViewIfLoaded,
               quote.bounds.contains(recognizer.location(in: quote)),
               let indexPath = self.indexPath(where: { $0.messageId == quoteMessageId })
            {
                tableView.scrollToRow(at: indexPath, at: .middle, animated: true)
                if let indexPaths = tableView.indexPathsForVisibleRows, indexPaths.contains(indexPath) {
                    flashCellBackground(at: indexPath)
                } else {
                    indexPathToFlashAfterAnimationFinished = indexPath
                }
            } else if message.category.hasSuffix("_AUDIO"), message.mediaStatus == MediaStatus.DONE.rawValue || message.mediaStatus == MediaStatus.READ.rawValue {
                if audioManager.playingMessage?.messageId == message.messageId, audioManager.player?.status == .playing {
                    audioManager.pause()
                } else if CallService.shared.hasCall {
                    alert(R.string.localizable.chat_voice_record_on_call())
                } else {
                    (cell as? AudioMessageCell)?.updateUnreadStyle()
                    audioManager.play(message: message)
                    didPlayAudioMessage = true
                }
            } else if (isImageOrVideo && mediaStatusIsReady) || message.category.hasSuffix("_LIVE"),
                      let galleryViewController = UIApplication.homeContainerViewController?.galleryViewController,
                      let cell = cell as? PhotoRepresentableMessageCell
            {
                var items: [GalleryItem] = []
                for date in dates {
                    guard let viewModels = viewModels[date] else {
                        continue
                    }
                    let new = viewModels.compactMap(GalleryItem.init)
                    items.append(contentsOf: new)
                }
                if let index = items.firstIndex(where: { $0.messageId == message.messageId }) {
                    galleryViewController.conversationId = nil
                    galleryViewController.show(items: items, index: index, from: cell)
                }
            } else if message.category.hasSuffix("_DATA"), let viewModel = viewModel as? DataMessageViewModel, let cell = cell as? DataMessageCell {
                if viewModel.mediaStatus == MediaStatus.DONE.rawValue || viewModel.mediaStatus == MediaStatus.READ.rawValue {
                    if let filename = message.mediaUrl {
                        //TODO: ‼️ fix AttachmentContainer.url(transcriptId
                        let url = AttachmentContainer.url(transcriptId: staticMessageId, filename: filename)
                        if FileManager.default.fileExists(atPath: url.path) {
                            let controller = UIDocumentInteractionController(url: url)
                            controller.delegate = self
                            if !controller.presentPreview(animated: true) {
                                controller.presentOpenInMenu(from: CGRect.zero, in: view, animated: true)
                            }
                        }
                    }
                } else {
                    attachmentLoadingCellDidSelectNetworkOperation(cell)
                }
            } else if message.category.hasSuffix("_CONTACT"), let shareUserId = message.sharedUserId {
                if shareUserId == myUserId {
                    guard let account = LoginManager.shared.account else {
                        return
                    }
                    let user = UserItem.createUser(from: account)
                    let vc = UserProfileViewController(user: user)
                    present(vc, animated: true, completion: nil)
                } else if let user = UserDAO.shared.getUser(userId: shareUserId), user.isCreatedByMessenger {
                    let vc = UserProfileViewController(user: user)
                    present(vc, animated: true, completion: nil)
                }
            } else if message.category.hasSuffix("_POST") {
                let message = Message.createMessage(message: message)
                PostWebViewController.presentInstance(message: message, asChildOf: self)
            } else if message.category.hasSuffix("_LOCATION"), let location = message.location {
                let vc = LocationPreviewViewController(location: location)
                let container = ContainerViewController.instance(viewController: vc, title: R.string.localizable.chat_menu_location())
                navigationController?.pushViewController(container, animated: true)
            } else if message.category == MessageCategory.APP_CARD.rawValue, let appCard = message.appCard {
                if let appId = appCard.appId, !appId.isEmpty {
                    DispatchQueue.global().async { [weak self] in
                        var app = AppDAO.shared.getApp(appId: appId)
                        if app == nil {
                            if case let .success(response) = UserAPI.showUser(userId: appId) {
                                UserDAO.shared.updateUsers(users: [response])
                                app = response.app
                            }
                        }
                        guard let self = self, let app = app else {
                            return
                        }
                        DispatchQueue.main.async {
                            guard !UrlWindow.checkUrl(url: appCard.action) else {
                                return
                            }
                            let context = MixinWebViewController.Context(conversationId: "", url: appCard.action, app: app)
                            MixinWebViewController.presentInstance(with: context, asChildOf: self)
                        }
                    }
                }
            } else if message.category.hasSuffix("_TRANSCRIPT") {
                let vc = TranscriptPreviewViewController(transcriptMessage: message)
                vc.presentAsChild(of: self, completion: nil)
            }
        }
    }
    //TODO: ‼️ fix this, recall message
    @objc private func conversationDidChange(_ sender: Notification) {
        guard
            let change = sender.object as? ConversationChange,
            case .recallMessage(let messageId) = change.action,
            messageId == staticMessageId
        else {
            return
        }
        dismissAsChild(completion: nil)
    }
    
    @objc private func menuControllerWillHideMenu(_ notification: Notification) {
        if let indexPath = tableView.indexPathForSelectedRow {
            tableView.deselectRow(at: indexPath, animated: true)
        }
        NotificationCenter.default.removeObserver(self,
                                                  name: UIMenuController.willHideMenuNotification,
                                                  object: nil)
    }
    
    @objc private func menuControllerDidHideMenu(_ notification: Notification) {
        UIMenuController.shared.menuItems = nil
        NotificationCenter.default.removeObserver(self,
                                                  name: UIMenuController.didHideMenuNotification,
                                                  object: nil)
    }
    
    @objc private func showCopyMenu(_ recognizer: UIGestureRecognizer) {
        guard recognizer.state == .began else {
            return
        }
        let location = recognizer.location(in: tableView)
        guard
            let cell = tableView.messageCellForRow(at: location),
            let indexPath = tableView.indexPath(for: cell),
            let viewModel = viewModel(at: indexPath),
            viewModel.message.category.hasSuffix("_TEXT")
        else {
            return
        }
        tableView.selectRow(at: indexPath, animated: true, scrollPosition: .none)
        becomeFirstResponder()
        UIMenuController.shared.menuItems = [
            UIMenuItem(title: R.string.localizable.action_copy(),
                       action: #selector(copySelectedMessage))
        ]
        UIMenuController.shared.setTargetRect(cell.contentFrame, in: cell)
        UIMenuController.shared.setMenuVisible(true, animated: true)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(menuControllerWillHideMenu(_:)),
                                               name: UIMenuController.willHideMenuNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(menuControllerDidHideMenu(_:)),
                                               name: UIMenuController.didHideMenuNotification,
                                               object: nil)
        AppDelegate.current.mainWindow.addDismissMenuResponder()
    }
    
    @objc private func copySelectedMessage() {
        guard let indexPath = tableView.indexPathForSelectedRow else {
            return
        }
        guard let message = viewModel(at: indexPath)?.message else {
            return
        }
        UIPasteboard.general.string = message.content
    }
    
}

// MARK: - Private works
extension StaticMessagesViewController {
    
    private final class ViewModelFactory: MessageViewModelFactory {
        
        override func style(forIndex index: Int,
                            isFirstMessage: Bool,
                            isLastMessage: Bool,
                            messageAtIndex: (Int) -> MessageItem) -> MessageViewModel.Style {
            var style = super.style(forIndex: index,
                                    isFirstMessage: isFirstMessage,
                                    isLastMessage: isLastMessage,
                                    messageAtIndex: messageAtIndex)
            style.insert(.noStatus)
            return style
        }
        
    }
    
    private func viewModels(at section: Int) -> [MessageViewModel]? {
        guard section < dates.count else {
            return nil
        }
        let date = dates[section]
        return viewModels[date]
    }
    
    private func viewModel(at indexPath: IndexPath) -> MessageViewModel? {
        guard let viewModels = viewModels(at: indexPath.section), indexPath.row < viewModels.count else {
            return nil
        }
        return viewModels[indexPath.row]
    }
    
    private func indexPath(where predicate: (MessageItem) -> Bool) -> IndexPath? {
        for (section, date) in dates.enumerated() {
            let viewModels = viewModels[date]!
            for (row, viewModel) in viewModels.enumerated() {
                if predicate(viewModel.message) {
                    return IndexPath(row: row, section: section)
                }
            }
        }
        return nil
    }
    
    private func flashCellBackground(at indexPath: IndexPath) {
        guard let cell = tableView.cellForRow(at: indexPath) as? DetailInfoMessageCell else {
            return
        }
        cell.updateAppearance(highlight: true, animated: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: {
            cell.updateAppearance(highlight: false, animated: true)
        })
    }
    
    private func open(url: URL) {
        guard !UrlWindow.checkUrl(url: url) else {
            return
        }
        guard let parent = parent else {
            return
        }
        MixinWebViewController.presentInstance(with: .init(conversationId: "", initialUrl: url), asChildOf: parent)
    }
    
    @available(iOS 13.0, *)
    private func contextMenuConfigurationForRow(at indexPath: IndexPath) -> UIContextMenuConfiguration? {
        guard !alwaysUsesLegacyMenu else {
            return nil
        }
        guard !tableView.allowsMultipleSelection, let message = viewModel(at: indexPath)?.message else {
            return nil
        }
        guard message.category.hasSuffix("_TEXT") else {
            return nil
        }
        let copyAction = UIAction(title: R.string.localizable.action_copy(), image: R.image.conversation.ic_action_copy()) { _ in
            UIPasteboard.general.string = message.content
        }
        let identifier = message.messageId as NSString
        return UIContextMenuConfiguration(identifier: identifier, previewProvider: nil) { (elements) -> UIMenu? in
            UIMenu(title: "", children: [copyAction])
        }
    }
    
    @available(iOS 13.0, *)
    private func previewForContextMenu(with configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard !alwaysUsesLegacyMenu else {
            return nil
        }
        guard let identifier = configuration.identifier as? NSString else {
            return nil
        }
        let messageId = identifier as String
        guard
            let indexPath = indexPath(where: { $0.messageId == messageId }),
            let cell = tableView.cellForRow(at: indexPath) as? MessageCell,
            cell.window != nil,
            let viewModel = viewModel(at: indexPath)
        else {
            return nil
        }
        let param = UIPreviewParameters()
        param.backgroundColor = .clear
        
        if let viewModel = viewModel as? StickerMessageViewModel {
            param.visiblePath = UIBezierPath(roundedRect: viewModel.contentFrame,
                                             cornerRadius: StickerMessageCell.contentCornerRadius)
        } else if let viewModel = viewModel as? AppButtonGroupViewModel {
            param.visiblePath = UIBezierPath(roundedRect: viewModel.buttonGroupFrame,
                                             cornerRadius: AppButtonView.cornerRadius)
        } else {
            if viewModel.style.contains(.received) {
                if viewModel.style.contains(.tail) {
                    param.visiblePath = BubblePath.leftWithTail(frame: viewModel.backgroundImageFrame)
                } else {
                    param.visiblePath = BubblePath.left(frame: viewModel.backgroundImageFrame)
                }
            } else {
                if viewModel.style.contains(.tail) {
                    param.visiblePath = BubblePath.rightWithTail(frame: viewModel.backgroundImageFrame)
                } else {
                    param.visiblePath = BubblePath.right(frame: viewModel.backgroundImageFrame)
                }
            }
        }
        
        return UITargetedPreview(view: cell.messageContentView, parameters: param)
    }
    
    private func updatePreferredContentSizeHeight() {
        guard !isBeingDismissed else {
            return
        }
        view.layoutIfNeeded()
        let window = AppDelegate.current.mainWindow
        let height = window.bounds.height - window.safeAreaInsets.top
        preferredContentSize.height = height
        view.frame.origin.y = backgroundButton.bounds.height - height
    }
    
}

// MARK: - MessageViewModelFactoryDelegate
extension StaticMessagesViewController: MessageViewModelFactoryDelegate {
    
    func messageViewModelFactory(_ factory: MessageViewModelFactory, showUsernameForMessageIfNeeded message: MessageItem) -> Bool {
        message.userId != myUserId
    }
    
    func messageViewModelFactory(_ factory: MessageViewModelFactory, isMessageForwardedByBot message: MessageItem) -> Bool {
        false
    }
    
    func messageViewModelFactory(_ factory: MessageViewModelFactory, updateViewModelForPresentation viewModel: MessageViewModel) {
        
    }
    
}

// MARK: - UITableViewDataSource
extension StaticMessagesViewController: UITableViewDataSource {
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        viewModels(at: section)?.count ?? 0
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let viewModel = viewModel(at: indexPath) else {
            return self.tableView.dequeueReusableCell(withReuseId: .unknown, for: indexPath)
        }
        let cell = self.tableView.dequeueReusableCell(withMessage: viewModel.message, for: indexPath)
        if let cell = cell as? AttachmentLoadingMessageCell {
            cell.attachmentLoadingDelegate = self
        }
        if let cell = cell as? DetailInfoMessageCell {
            cell.delegate = self
        }
        if let cell = cell as? TextMessageCell {
            cell.contentLabel.delegate = self
        }
        if let cell = cell as? AudioMessageCell {
            cell.audioMessagePlayingManager = audioManager
        }
        if let cell = cell as? MessageCell {
            CATransaction.performWithoutAnimation {
                cell.render(viewModel: viewModel)
                cell.layoutIfNeeded()
            }
        }
        return cell
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        dates.count
    }
    
}

// MARK: - UIScrollViewDelegate
extension StaticMessagesViewController: UIScrollViewDelegate {
    
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if let indexPath = indexPathToFlashAfterAnimationFinished {
            flashCellBackground(at: indexPath)
            indexPathToFlashAfterAnimationFinished = nil
        }
    }
    
}

// MARK: - UITableViewDelegate
extension StaticMessagesViewController: UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if let viewModel = viewModel(at: indexPath) as? AttachmentLoadingViewModel, viewModel.automaticallyLoadsAttachment {
            viewModel.beginAttachmentLoading(isTriggeredByUser: false)
        }
        if let cell = cell as? AttachmentLoadingMessageCell {
            cell.updateOperationButtonStyle()
        }
    }
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard let viewModel = viewModel(at: indexPath) else {
            return 1
        }
        if viewModel.cellHeight.isNaN || viewModel.cellHeight < 1 {
            return 1
        } else {
            return viewModel.cellHeight
        }
    }
    
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return ConversationDateHeaderView.height
    }
    
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: ConversationTableView.ReuseId.header.rawValue) as! ConversationDateHeaderView
        let date = dates[section]
        header.label.text = DateFormatter.yyyymmdd.date(from: date)?.chatTimeAgo()
        return header
    }
    
    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        nil
    }
    
    @available(iOS 13.0, *)
    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        if let label = tableView.hitTest(point, with: nil) as? TextMessageLabel, label.canResponseTouch(at: tableView.convert(point, to: label)) {
            return nil
        } else {
            return contextMenuConfigurationForRow(at: indexPath)
        }
    }
    
    @available(iOS 13.0, *)
    func tableView(_ tableView: UITableView, previewForHighlightingContextMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        previewForContextMenu(with: configuration)
    }
    
    @available(iOS 13.0, *)
    func tableView(_ tableView: UITableView, previewForDismissingContextMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        previewForContextMenu(with: configuration)
    }
    
}

// MARK: - AttachmentLoadingMessageCellDelegate
extension StaticMessagesViewController: AttachmentLoadingMessageCellDelegate {
    
    func attachmentLoadingCellDidSelectNetworkOperation(_ cell: UITableViewCell & AttachmentLoadingMessageCell) {
        guard let indexPath = tableView.indexPath(for: cell), let viewModel = viewModel(at: indexPath) as? MessageViewModel & AttachmentLoadingViewModel else {
            return
        }
        switch viewModel.operationButtonStyle {
        case .download, .upload:
            viewModel.beginAttachmentLoading(isTriggeredByUser: true)
            viewModel.operationButtonStyle = .busy(progress: 0)
        case .busy:
            viewModel.cancelAttachmentLoading(isTriggeredByUser: true)
            viewModel.operationButtonStyle = .download
        case .expired, .finished:
            break
        }
        cell.updateOperationButtonStyle()
    }
    
}

// MARK: - UIDocumentInteractionControllerDelegate
extension StaticMessagesViewController: UIDocumentInteractionControllerDelegate {
    
    func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
        self
    }
    
}

// MARK: - DetailInfoMessageCellDelegate
extension StaticMessagesViewController: DetailInfoMessageCellDelegate {
    
    func detailInfoMessageCellDidSelectFullname(_ cell: DetailInfoMessageCell) {
        guard
            let indexPath = tableView.indexPath(for: cell),
            let message = viewModel(at: indexPath)?.message,
            let user = UserDAO.shared.getUser(userId: message.userId)
        else {
            return
        }
        let vc = UserProfileViewController(user: user)
        present(vc, animated: true, completion: nil)
    }
    
}

// MARK: - CoreTextLabelDelegate
extension StaticMessagesViewController: CoreTextLabelDelegate {
    
    func coreTextLabel(_ label: CoreTextLabel, didSelectURL url: URL) {
        guard !openUrlOutsideApplication(url) else {
            return
        }
        open(url: url)
    }
    
    func coreTextLabel(_ label: CoreTextLabel, didLongPressOnURL url: URL) {
        guard url.scheme != MixinInternalURL.scheme else {
            return
        }
        let alert = UIAlertController(title: url.absoluteString, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: Localized.CHAT_MESSAGE_OPEN_URL, style: .default, handler: { [weak self](_) in
            self?.open(url: url)
        }))
        alert.addAction(UIAlertAction(title: Localized.CHAT_MESSAGE_MENU_COPY, style: .default, handler: { (_) in
            UIPasteboard.general.string = url.absoluteString
            showAutoHiddenHud(style: .notification, text: Localized.TOAST_COPIED)
            
        }))
        alert.addAction(UIAlertAction(title: Localized.DIALOG_BUTTON_CANCEL, style: .cancel, handler: nil))
        present(alert, animated: true, completion: nil)
    }
    
}

// MARK: - UIGestureRecognizerDelegate
extension StaticMessagesViewController: UIGestureRecognizerDelegate {
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if let view = touch.view as? TextMessageLabel {
            return !view.canResponseTouch(at: touch.location(in: view))
        } else {
            return true
        }
    }
    
}

// MARK: - StaticAudioMessagePlayingManagerDelegate
extension StaticMessagesViewController: StaticAudioMessagePlayingManagerDelegate {
    
    func staticAudioMessagePlayingManager(_ manager: StaticAudioMessagePlayingManager, playableMessageNextTo message: MessageItem) -> MessageItem? {
        guard var indexPath = indexPath(where: { $0.messageId == message.messageId }) else {
            return nil
        }
        indexPath.row += 1
        if let message = viewModel(at: indexPath)?.message, message.category == MessageCategory.SIGNAL_AUDIO.rawValue {
            return message
        } else {
            return nil
        }
    }
    
}

// MARK: - Attachment Callbacks
extension StaticMessagesViewController {
    
    @objc private func updateAttachmentProgress(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let messageId = userInfo[AttachmentLoadingJob.UserInfoKey.messageId] as? String,
            let progress = userInfo[AttachmentLoadingJob.UserInfoKey.progress] as? Double,
            let indexPath = indexPath(where: { $0.messageId == messageId })
        else {
            return
        }
        if let viewModel = viewModel(at: indexPath) as? MessageViewModel & AttachmentLoadingViewModel {
            viewModel.progress = progress
        }
        if let cell = tableView.cellForRow(at: indexPath) as? AttachmentLoadingMessageCell {
            cell.updateProgress()
        }
    }
    
    @objc private func updateMessageMediaStatus(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let messageId = userInfo[MessageDAO.UserInfoKey.messageId] as? String,
            let mediaStatus = userInfo[MessageDAO.UserInfoKey.mediaStatus] as? MediaStatus,
            let indexPath = indexPath(where: { $0.messageId == messageId })
        else {
            return
        }
        let viewModel = viewModel(at: indexPath)
        let cell = tableView?.cellForRow(at: indexPath)
        if let viewModel = viewModel as? AttachmentLoadingViewModel {
            viewModel.mediaStatus = mediaStatus.rawValue
            if let cell = cell as? (PhotoRepresentableMessageCell & AttachmentExpirationHintingMessageCell) {
                cell.updateOperationButtonAndExpiredHintLabel()
            } else if let cell = cell as? AttachmentLoadingMessageCell {
                cell.updateOperationButtonStyle()
            }
        } else {
            viewModel?.message.mediaStatus = mediaStatus.rawValue
        }
        if let cell = cell as? AudioMessageCell {
            cell.updateUnreadStyle()
        }
    }
    
}
