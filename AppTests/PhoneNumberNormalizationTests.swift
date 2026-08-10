import Contacts
import Foundation
import XCTest

@testable import iMCP

/// Contacts-side phone-number region resolution and E.164 normalization: the persisted
/// region setting, the live effective-region seam, the PhoneNumberKit adapter, and the
/// labeled-value builder `CNContactStoreSearch` uses to assemble the additive
/// `phoneNumbers` fact.
///
/// Every phone number here is a publicly documented fictional-use test number — the NANP
/// 555-01XX convention reserved for the US, and Ofcom's 020 7946 09XX block reserved for
/// UK drama and fiction — never a real subscriber's number.
final class PhoneNumberNormalizationTests: XCTestCase {

    // MARK: - Region setting storage

    func testAbsentOrEmptyOrLiteralSystemDecodesToSystem() {
        for stored in [nil, "", "system"] {
            XCTAssertEqual(PhoneNumberRegionSetting.decode(stored), .system, stored ?? "nil")
        }
    }

    func testARecognizedRegionCodeDecodesToThatOverride() {
        XCTAssertEqual(PhoneNumberRegionSetting.decode("GB"), .override("GB"))
    }

    func testAnUnrecognizedOrStaleStoredValueFallsBackToSystemRatherThanGuessing() {
        // A stored value could be stale after an OS upgrade retires a region code, or
        // corrupted by hand-edited defaults. Either way this must never crash or guess.
        for stored in ["ZZ", "not-a-region", "US "] {
            XCTAssertEqual(PhoneNumberRegionSetting.decode(stored), .system, stored)
        }
    }

    func testRoundTripThroughRawValuePreservesTheSetting() {
        XCTAssertEqual(
            PhoneNumberRegionSetting.decode(PhoneNumberRegionSetting.system.rawValue),
            .system
        )
        XCTAssertEqual(
            PhoneNumberRegionSetting.decode(PhoneNumberRegionSetting.override("FR").rawValue),
            .override("FR")
        )
    }

    // MARK: - Effective region resolution

    func testAnExplicitOverrideWinsRegardlessOfTheSystemRegion() {
        let provider = SystemEffectiveRegionProvider(
            overrideSetting: { .override("JP") },
            systemRegionCode: { "US" }
        )
        XCTAssertEqual(provider.regionCode, "JP")
    }

    func testWithNoOverrideTheCurrentSystemRegionIsUsedAndReadFreshEachTime() {
        let systemRegion = MutableBox("US")
        let provider = SystemEffectiveRegionProvider(
            overrideSetting: { .system },
            systemRegionCode: { systemRegion.value }
        )
        XCTAssertEqual(provider.regionCode, "US")

        // Changing what the system reports changes the very next read — no snapshot taken
        // at construction, no service reconstruction required.
        systemRegion.value = "DE"
        XCTAssertEqual(provider.regionCode, "DE")
    }

    func testTheOverrideSettingIsAlsoReadFreshOnEveryAccess() {
        let setting = MutableBox(PhoneNumberRegionSetting.system)
        let provider = SystemEffectiveRegionProvider(
            overrideSetting: { setting.value },
            systemRegionCode: { "US" }
        )
        XCTAssertEqual(provider.regionCode, "US")

        setting.value = .override("CA")
        XCTAssertEqual(provider.regionCode, "CA")
    }

    func testAMissingSystemRegionPublishesNoEffectiveRegionRatherThanGuessing() {
        let provider = SystemEffectiveRegionProvider(
            overrideSetting: { .system },
            systemRegionCode: { nil }
        )
        XCTAssertNil(provider.regionCode)
    }

    // MARK: - Region catalog validation

    func testKnownRegionCodesValidate() {
        XCTAssertTrue(PhoneNumberRegionCatalog.isValidRegionCode("US"))
        XCTAssertTrue(PhoneNumberRegionCatalog.isValidRegionCode("GB"))
    }

    func testUnknownRegionCodesDoNotValidate() {
        XCTAssertFalse(PhoneNumberRegionCatalog.isValidRegionCode("ZZ"))
        XCTAssertFalse(PhoneNumberRegionCatalog.isValidRegionCode(""))
    }

    func testAnISORegionUnsupportedByPhoneNumberKitFallsBackToSystem() throws {
        let unsupportedRegion = try XCTUnwrap(
            Locale.Region.isoRegions.map(\.identifier).first {
                !PhoneNumberKitNormalizer.shared.supportedRegionCodes.contains($0)
            }
        )

        XCTAssertEqual(PhoneNumberRegionSetting.decode(unsupportedRegion), .system)
        XCTAssertFalse(PhoneNumberRegionCatalog.regionCodes.contains(unsupportedRegion))
    }

    // MARK: - Production normalizer (real PhoneNumberKit metadata)

    private let explicitE164 = "+12025550123"
    private let usLocalFormat = "(202) 555-0123"
    private let gbLocalFormat = "020 7946 0958"
    private let gbE164 = "+442079460958"

    func testAnExplicitE164ValueNormalizesIdenticallyUnderMateriallyDifferentRegions() {
        let normalizer = PhoneNumberKitNormalizer.shared
        XCTAssertEqual(normalizer.e164(for: explicitE164, region: "US"), explicitE164)
        XCTAssertEqual(normalizer.e164(for: explicitE164, region: "GB"), explicitE164)
        XCTAssertEqual(normalizer.e164(for: explicitE164, region: "FR"), explicitE164)
        XCTAssertEqual(normalizer.e164(for: explicitE164, region: "ZZ"), explicitE164)
        XCTAssertEqual(normalizer.e164(for: explicitE164, region: nil), explicitE164)
    }

    func testALocalFormatNumberNormalizesUnderItsOwnRegion() {
        let normalizer = PhoneNumberKitNormalizer.shared
        XCTAssertEqual(normalizer.e164(for: usLocalFormat, region: "US"), explicitE164)
        XCTAssertEqual(normalizer.e164(for: gbLocalFormat, region: "GB"), gbE164)
    }

    func testTheSameLocalValueProducesDifferentOutcomesUnderDifferentRegions() {
        // The identical raw value normalizes under the region that matches it and fails to
        // parse under one that does not: proof the effective region actually governs
        // interpretation rather than being cosmetic.
        let normalizer = PhoneNumberKitNormalizer.shared
        XCTAssertNotNil(normalizer.e164(for: gbLocalFormat, region: "GB"))
        XCTAssertNil(normalizer.e164(for: gbLocalFormat, region: "US"))
    }

    func testAnInvalidLocalNumberPublishesNoIdentityRatherThanGuessing() {
        let normalizer = PhoneNumberKitNormalizer.shared
        for garbage in ["not a number", "123", ""] {
            XCTAssertNil(normalizer.e164(for: garbage, region: "US"), garbage)
        }
    }

    func testALocalValueWithNoEffectiveRegionPublishesNoIdentityRatherThanGuessing() {
        XCTAssertNil(PhoneNumberKitNormalizer.shared.e164(for: usLocalFormat, region: nil))
    }

    // MARK: - CNContactStoreSearch label + normalization assembly

    func testStandardLabelIsPreservedAsALocalizedDisplayString() {
        let labeled = CNLabeledValue(
            label: CNLabelPhoneNumberMobile,
            value: CNPhoneNumber(stringValue: usLocalFormat)
        )
        let fact = CNContactStoreSearch.phoneNumber(
            from: labeled,
            region: "US",
            normalizer: FakeNormalizer(fixed: explicitE164)
        )
        XCTAssertEqual(fact.value, usLocalFormat)
        XCTAssertEqual(
            fact.label,
            CNLabeledValue<NSString>.localizedString(forLabel: CNLabelPhoneNumberMobile)
        )
        XCTAssertEqual(fact.e164, explicitE164)
    }

    func testCustomLabelIsPreservedVerbatim() {
        let labeled = CNLabeledValue(
            label: "Synthetic Custom Label",
            value: CNPhoneNumber(stringValue: usLocalFormat)
        )
        let fact = CNContactStoreSearch.phoneNumber(
            from: labeled,
            region: "US",
            normalizer: FakeNormalizer(fixed: nil)
        )
        XCTAssertEqual(fact.label, "Synthetic Custom Label")
        XCTAssertNil(fact.e164)
    }

    func testNilLabelBecomesNilWithoutCrashingOrLogging() {
        let labeled = CNLabeledValue<CNPhoneNumber>(
            label: nil,
            value: CNPhoneNumber(stringValue: usLocalFormat)
        )
        let fact = CNContactStoreSearch.phoneNumber(
            from: labeled,
            region: "US",
            normalizer: FakeNormalizer(fixed: nil)
        )
        XCTAssertNil(fact.label)
    }

    func testTheResolvedRegionAndRawValueAreWhatReachTheNormalizer() {
        let recorder = RecordingNormalizer()
        _ = CNContactStoreSearch.phoneNumber(
            from: CNLabeledValue(
                label: CNLabelHome,
                value: CNPhoneNumber(stringValue: gbLocalFormat)
            ),
            region: "GB",
            normalizer: recorder
        )
        XCTAssertEqual(recorder.values, [gbLocalFormat])
        XCTAssertEqual(recorder.regions, ["GB"])
    }

    func testEndToEndWithTheRealNormalizerProducesTheAdditiveFactAndLeavesTheRawValueAlone() {
        let labeled = CNLabeledValue(
            label: CNLabelPhoneNumberMobile,
            value: CNPhoneNumber(stringValue: gbLocalFormat)
        )
        let fact = CNContactStoreSearch.phoneNumber(
            from: labeled,
            region: "GB",
            normalizer: PhoneNumberKitNormalizer.shared
        )
        XCTAssertEqual(fact.value, gbLocalFormat)
        XCTAssertEqual(fact.e164, gbE164)
    }
}

/// A lock-protected mutable value, standing in for state that changes between two reads of
/// a live seam (system region, Settings override) without ever being snapshotted.
private final class MutableBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private struct FakeNormalizer: PhoneNumberNormalizing {
    let fixed: String?
    func e164(for rawValue: String, region: String?) -> String? { fixed }
}

private final class RecordingNormalizer: PhoneNumberNormalizing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String] = []
    private var storedRegions: [String?] = []

    var values: [String] { lock.withLock { storedValues } }
    var regions: [String?] { lock.withLock { storedRegions } }

    func e164(for rawValue: String, region: String?) -> String? {
        lock.withLock {
            storedValues.append(rawValue)
            storedRegions.append(region)
        }
        return nil
    }
}
