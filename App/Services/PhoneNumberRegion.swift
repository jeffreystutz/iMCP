import Foundation

/// The phone-number region a local-format Contacts number is interpreted under.
///
/// `.system` follows the Mac's current region and is the default. `.override` pins
/// interpretation to one explicit region regardless of what the system reports. Neither
/// case affects an already-explicit international number, which never depends on region.
enum PhoneNumberRegionSetting: Hashable, Sendable {
    case system
    case override(String)

    static let storageKey = "me.mattt.iMCP.phoneNumberRegion"
    static let defaultValue = PhoneNumberRegionSetting.system

    /// The literal sentinel stored for `.system`, kept distinct from any real region code.
    private static let systemStorageValue = "system"

    var rawValue: String {
        switch self {
        case .system: Self.systemStorageValue
        case .override(let regionCode): regionCode
        }
    }

    /// Decodes a stored value, falling back to `.system` for anything absent, empty, or no
    /// longer a recognized region — a stale value must never be guessed at or crash.
    static func decode(_ storedValue: String?) -> PhoneNumberRegionSetting {
        guard let storedValue, storedValue != systemStorageValue, !storedValue.isEmpty else {
            return .system
        }
        guard PhoneNumberRegionCatalog.isValidRegionCode(storedValue) else { return .system }
        return .override(storedValue)
    }

    static func load(from defaults: UserDefaults = .standard) -> PhoneNumberRegionSetting {
        decode(defaults.string(forKey: storageKey))
    }
}

/// The known region codes a user may explicitly select, and validation for stored values.
enum PhoneNumberRegionCatalog {
    /// PhoneNumberKit-supported ISO region codes with a localized display name, sorted
    /// for a settings picker.
    static var regionCodes: [String] {
        PhoneNumberKitNormalizer.shared.supportedRegionCodes
            .filter { Locale.current.localizedString(forRegionCode: $0) != nil }
            .sorted {
                displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1))
                    == .orderedAscending
            }
    }

    static func displayName(for regionCode: String) -> String {
        Locale.current.localizedString(forRegionCode: regionCode) ?? regionCode
    }

    static func isValidRegionCode(_ regionCode: String) -> Bool {
        PhoneNumberKitNormalizer.shared.supportedRegionCodes.contains(regionCode)
    }
}

/// Resolves the region a local-format phone number is interpreted under, read fresh on
/// every access rather than snapshotted, so a Settings change or a system region change
/// takes effect on the next search without reconstructing any service.
protocol EffectiveRegionProviding: Sendable {
    var regionCode: String? { get }
}

/// Production region resolution: an explicit override when configured, otherwise the
/// Mac's live system region.
struct SystemEffectiveRegionProvider: EffectiveRegionProviding {
    private let overrideSetting: @Sendable () -> PhoneNumberRegionSetting
    private let systemRegionCode: @Sendable () -> String?

    init(
        overrideSetting: @escaping @Sendable () -> PhoneNumberRegionSetting = {
            PhoneNumberRegionSetting.load()
        },
        systemRegionCode: @escaping @Sendable () -> String? = {
            Locale.autoupdatingCurrent.region?.identifier
        }
    ) {
        self.overrideSetting = overrideSetting
        self.systemRegionCode = systemRegionCode
    }

    var regionCode: String? {
        switch overrideSetting() {
        case .override(let regionCode):
            return regionCode
        case .system:
            return systemRegionCode()
        }
    }
}
