import Testing
import Foundation
@testable import FandCore

@Suite struct HardwareTests {

    @Test func modelIdentifierIsNonEmpty() {
        let model = HardwareCaps.modelIdentifier()
        #expect(!model.isEmpty)
        // Every real identifier starts with "Mac" (e.g. "MacBookPro18,1").
        #expect(model.hasPrefix("Mac"))
    }

    @Test func knownModelCeilings() {
        #expect(HardwareCaps.ceiling(forModel: "MacBookPro18,1") == 6500)
        #expect(HardwareCaps.ceiling(forModel: "MacBookPro18,4") == 6000)
        #expect(HardwareCaps.ceiling(forModel: "Mac15,6") == 6500)
        #expect(HardwareCaps.ceiling(forModel: "Mac16,7") == 6000)
        #expect(HardwareCaps.ceiling(forModel: "Mac14,7") == 7000)
        #expect(HardwareCaps.ceiling(forModel: "MacBookPro17,1") == 7000)
    }

    @Test func unknownModelFallsBackToAbsoluteCeiling() {
        #expect(HardwareCaps.ceiling(forModel: "Mac99,9") == HardwareCaps.absoluteCeiling)
        #expect(HardwareCaps.ceiling(forModel: "not-a-model") == HardwareCaps.absoluteCeiling)
    }

    @Test func firmwareMaxWinsWhenPlausible() {
        let limit = HardwareCaps.effectiveLimit(firmwareMax: 4296, model: "MacBookPro18,1")
        #expect(limit.value == 4296)
        #expect(limit.source == "firmware F0Mx")
    }

    @Test func missingFirmwareMaxFallsBackToModelCeiling() {
        let limit = HardwareCaps.effectiveLimit(firmwareMax: nil, model: "MacBookPro18,1")
        #expect(limit.value == 6500)
        #expect(limit.source.contains("model ceiling"))
    }

    @Test func garbageFirmwareMaxFallsBack() {
        // Corrupt reads must never be taken at face value.
        #expect(HardwareCaps.effectiveLimit(firmwareMax: 999_999, model: "MacBookPro18,1").value == 6500)
        #expect(HardwareCaps.effectiveLimit(firmwareMax: 0, model: "MacBookPro18,1").value == 6500)
        #expect(HardwareCaps.effectiveLimit(firmwareMax: -5, model: "MacBookPro18,1").value == 6500)
        #expect(HardwareCaps.effectiveLimit(firmwareMax: .nan, model: "MacBookPro18,1").value == 6500)
        #expect(HardwareCaps.effectiveLimit(firmwareMax: .infinity, model: "MacBookPro18,1").value == 6500)
    }

    @Test func firmwareAboveCeilingIsCapped() {
        // Firmware claims more than this model can physically do → ceiling.
        let limit = HardwareCaps.effectiveLimit(firmwareMax: 8500, model: "MacBookPro18,1")
        #expect(limit.value == 6500)
        #expect(limit.source.contains("model ceiling"))
    }

    @Test func unknownModelUsesFirmwareWithinAbsoluteCeiling() {
        // Unknown model: firmware governs as long as it stays under the
        // absolute ceiling; beyond it, the absolute ceiling applies.
        #expect(HardwareCaps.effectiveLimit(firmwareMax: 8000, model: "Mac99,9").value == 8000)
        #expect(HardwareCaps.effectiveLimit(firmwareMax: 9500, model: "Mac99,9").value == 9000)
        #expect(HardwareCaps.effectiveLimit(firmwareMax: 9500, model: "Mac99,9").source == "absolute ceiling")
    }

    @Test func tableSanity() {
        // Every table entry must be positive and at or below the absolute
        // ceiling (the absolute ceiling is the upper bound of the whole table).
        for (model, ceiling) in HardwareCaps.modelCeilings {
            #expect(ceiling > 0, "model \(model) has non-positive ceiling")
            #expect(ceiling <= HardwareCaps.absoluteCeiling, "model \(model) ceiling \(ceiling) exceeds absolute ceiling")
        }
    }

    @Test func effectiveLimitNeverAboveCeiling() {
        // For every known model, even an absurd firmware read must yield a
        // limit at or below the model's ceiling.
        for (model, ceiling) in HardwareCaps.modelCeilings {
            let limit = HardwareCaps.effectiveLimit(firmwareMax: 99_999, model: model)
            #expect(limit.value <= ceiling, "model \(model) effective limit \(limit.value) above ceiling \(ceiling)")
            #expect(limit.value == ceiling)
        }
    }
}
