import UIKit
import MixinServices

final class PrivacySettingViewController: SettingsTableViewController {
    
    private let dataSource = SettingsDataSource(sections: [
        SettingsSection(footer: R.string.localizable.setting_privacy_tip(), rows: [
            SettingsRow(title: R.string.localizable.blocked_Users(), accessory: .disclosure),
            SettingsRow(title: R.string.localizable.conversation(), accessory: .disclosure)
        ]),
        SettingsSection(rows: [
            SettingsRow(title: R.string.localizable.phone_Number(), accessory: .disclosure),
            SettingsRow(title: R.string.localizable.phone_Contacts(), accessory: .disclosure)
        ])
    ])
    
    private lazy var screenLockSection = SettingsSection(rows: [
        SettingsRow(title: R.string.localizable.screen_Lock(), subtitle: screenLockTimeoutInterval, accessory: .disclosure)
    ])
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    class func instance() -> UIViewController {
        let vc = PrivacySettingViewController()
        return ContainerViewController.instance(viewController: vc, title: R.string.localizable.privacy())
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        if biometryType != .none {
            dataSource.insertSection(screenLockSection, at: 2, animation: .none)
        }
        dataSource.tableViewDelegate = self
        dataSource.tableView = tableView
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(updateBlockedUserCell),
                                               name: UserDAO.userDidChangeNotification,
                                               object: nil)
        updateBlockedUserCell()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(updateScreenLockRow),
                                               name: ScreenLockSettingViewController.screenLockTimeoutDidUpdateNotification,
                                               object: nil)
    }
    
}

extension PrivacySettingViewController {
    
    @objc func updateBlockedUserCell() {
        DispatchQueue.global().async {
            let blocked = UserDAO.shared.getBlockUsers()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else {
                    return
                }
                let indexPath = IndexPath(row: 0, section: 0)
                let row = self.dataSource.row(at: indexPath)
                if blocked.count == 0 {
                    row.subtitle = R.string.localizable.none()
                } else if blocked.count == 1 {
                    row.subtitle = R.string.localizable.one_contact()
                } else {
                    row.subtitle = R.string.localizable.contacts_count(blocked.count)
                }
            }
        }
    }
    
    @objc private func updateScreenLockRow() {
        let indexPath = IndexPath(row: 0, section: 2)
        let row = dataSource.row(at: indexPath)
        row.subtitle = screenLockTimeoutInterval
    }
    
    private var screenLockTimeoutInterval: String {
        if AppGroupUserDefaults.User.lockScreenWithBiometricAuthentication {
            let timeInterval = AppGroupUserDefaults.User.lockScreenTimeoutInterval
            return ScreenLockTimeFormatter.string(from: timeInterval)
        } else {
            return R.string.localizable.off();
        }
    }
    
}

extension PrivacySettingViewController: UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let vc: UIViewController
        switch indexPath.section {
        case 0:
            if indexPath.row == 0 {
                vc = BlockedUsersViewController.instance()
            } else {
                vc = ConversationSettingViewController.instance()
            }
        case 1:
            if indexPath.row == 0 {
                vc = PhoneNumberSettingViewController.instance()
            } else {
                vc = PhoneContactsSettingViewController.instance()
            }
        default:
            if LoginManager.shared.account?.has_pin ?? false {
                vc = ScreenLockSettingViewController.instance()
            } else {
                vc = WalletPasswordViewController.instance(walletPasswordType: .initPinStep1, dismissTarget: nil)
            }
        }
        navigationController?.pushViewController(vc, animated: true)
    }
    
}
