import Foundation
import PhoneNumberKit

/// One phone value as Contacts stored it, together with its optional display label and
/// the E.164 identity it normalizes to under the effective region, if any.
///
/// This is additive: `value` is the same raw string a `Person.telephone` entry already
/// carries, so removing this fact from a response loses nothing a caller had before.
struct ContactPhoneNumber: Codable, Equatable, Sendable {
    /// The stored value exactly as Contacts holds it.
    let value: String
    /// A display label such as "mobile", "home", or "work", or a contact's own custom
    /// label. `nil` when Contacts has no label for this value.
    let label: String?
    /// The E.164 identity this value normalizes to under the effective region, or `nil`
    /// when it could not be parsed and validated. Never a guess: a `nil` here means no
    /// identity is published for this value, not that one was attempted and is uncertain.
    let e164: String?
}

/// Normalizes one raw phone value to E.164 under one effective region.
///
/// Kept behind a narrow seam so domain tests can inject a fake without loading real
/// numbering-plan metadata, while a separate adapter test exercises the production
/// implementation.
protocol PhoneNumberNormalizing: Sendable {
    /// Returns the E.164 identity for `rawValue` under `region`, or `nil` when the value
    /// cannot be parsed and validated under exactly that region. Never tries another
    /// region, never guesses, never repairs digits.
    func e164(for rawValue: String, region: String?) -> String?
}

/// Production normalization backed by PhoneNumberKit's maintained numbering-plan metadata.
///
/// `PhoneNumberUtility` loads its metadata once at initialization, so one instance is
/// created and reused rather than constructed per phone number. Its own regex cache is
/// internally lock-protected, so sharing one instance across concurrent contact searches
/// is safe.
final class PhoneNumberKitNormalizer: PhoneNumberNormalizing, @unchecked Sendable {
    static let shared = PhoneNumberKitNormalizer()

    private let utility: PhoneNumberUtility
    let supportedRegionCodes: Set<String>

    private init() {
        let utility = PhoneNumberUtility()
        self.utility = utility
        self.supportedRegionCodes = Set(utility.allCountries())
    }

    func e164(for rawValue: String, region: String?) -> String? {
        let hasInternationalPrefix =
            rawValue.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("+")

        // PhoneNumberKit requires a region argument even for an explicit international
        // number. In that case the country calling code in the value is authoritative, so
        // the library's default is only a parser seed and cannot invent the identity. A
        // local value with no effective region is rejected instead of guessed.
        let parsingRegion: String
        if hasInternationalPrefix {
            parsingRegion = PhoneNumberUtility.defaultRegionCode()
        } else if let region {
            parsingRegion = region
        } else {
            return nil
        }

        guard let parsed = try? utility.parse(rawValue, withRegion: parsingRegion, ignoreType: true)
        else { return nil }
        return utility.format(parsed, toType: .e164)
    }
}
