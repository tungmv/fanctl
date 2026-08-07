import Foundation

/// The effective maximum RPM for a fan, and where it came from.
public struct FanLimit: Equatable {
    public let value: Float
    public let source: String

    public init(value: Float, source: String) {
        self.value = value
        self.source = source
    }
}

/// Hardcoded, per-model fan-speed ceilings — the safety backstop that keeps a
/// user (or a corrupt firmware read) from ever requesting an absurd RPM.
///
/// Apple does not publish fan RPM specifications, so there is no official API.
/// The values below are **ceilings**, rounded *up* from measured maxima so
/// they can never undercut what the hardware can actually do:
///
/// - Notebookcheck reviews (measured max RPM under stress tests):
///   · 16" M1 Pro (2021): 4280 / 4750 RPM (left/right)
///   · 16" M1 Max (2021): 5348 / 5776 RPM
///   · 14" M3 Pro (2023): 6200–6300 RPM under stress
///   · 16" M3 Max (2023): 5349 / 5777 RPM
///   · 16" M4 Pro (2024): ~5560 RPM (High Performance mode)
/// - The Apple Wiki "Maximum RPM" rows: 14" 2021 = 5779 / 6241 RPM
/// - Apple's own support page (support.apple.com/HT201300) for the model
///   identifier of every MacBook Pro generation
/// - Community/firmware data: e.g. this project measured F0Mx = 4296 RPM on a
///   14" M1 Pro (MacBookPro18,1); Macs Fan Control issue tracker for the
///   2019 16" (6000 RPM) and other firmware values.
///
/// At runtime the firmware-reported `F0Mx` (the per-fan recommended maximum)
/// is always the primary limit — these ceilings only take over when the
/// firmware value is missing or implausible, and as an absolute bound so a
/// corrupt read can never be taken at face value.
public enum HardwareCaps {
    /// Absolute bound: no MacBook fan has ever been measured above this.
    /// (Highest observed figure: ~8000 RPM on the 2020 Intel MacBook Air.)
    public static let absoluteCeiling: Float = 9000

    /// Ceilings keyed by hardware model identifier (`hw.model`).
    /// Unknown models fall back to `absoluteCeiling` (firmware governs).
    public static let modelCeilings: [String: Float] = [
        // 13" MacBook Pro — single fan (Intel 13" siblings run ~6000–6500)
        "MacBookPro17,1": 7000,  // 13" M1, 2020
        "Mac14,7": 7000,         // 13" M2, 2022

        // 14" MacBook Pro 2021 (M1 Pro / M1 Max) — Apple Wiki max 5779/6241
        "MacBookPro18,1": 6500,  // 14" M1 Pro
        "MacBookPro18,3": 6500,  // 14" M1 Max

        // 16" MacBook Pro 2021 — Notebookcheck max 5348/5776
        "MacBookPro18,2": 6000,  // 16" M1 Pro
        "MacBookPro18,4": 6000,  // 16" M1 Max

        // 14"/16" MacBook Pro 2023 (M2 Pro / M2 Max) — same cooling as 2021
        "Mac14,5": 6500,         // 14" M2 Pro
        "Mac14,9": 6500,         // 14" M2 Max
        "Mac14,6": 6000,         // 16" M2 Pro
        "Mac14,10": 6000,        // 16" M2 Max

        // 14" MacBook Pro 2023–2024 (M3 / M3 Pro / M3 Max; M4 Pro / M4 Max)
        // — Notebookcheck stress max 6200–6300
        "Mac15,3": 6500,         // 14" M3
        "Mac15,6": 6500,         // 14" M3 Pro
        "Mac15,8": 6500,         // 14" M3 Pro (higher-end config)
        "Mac15,10": 6500,        // 14" M3 Max
        "Mac16,1": 6500,         // 14" M4
        "Mac16,6": 6500,         // 14" M4 Pro
        "Mac16,8": 6500,         // 14" M4 Max

        // 16" MacBook Pro 2023–2024 — Notebookcheck max 5349/5777, ~5560
        "Mac15,7": 6000,         // 16" M3 Pro
        "Mac15,9": 6000,         // 16" M3 Pro (higher-end config)
        "Mac15,11": 6000,        // 16" M3 Max
        "Mac16,5": 6000,         // 16" M4 Pro
        "Mac16,7": 6000,         // 16" M4 Max
    ]

    /// The `hw.model` identifier, e.g. "MacBookPro18,1".
    public static func modelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    /// The hardcoded ceiling for a model (absolute ceiling for unknown models).
    public static func ceiling(forModel model: String) -> Float {
        modelCeilings[model] ?? absoluteCeiling
    }

    /// The effective fan-speed limit: the firmware-reported `F0Mx` when it is
    /// plausible and within the model ceiling, otherwise the hardcoded
    /// ceiling. Never returns a value above the model's ceiling.
    public static func effectiveLimit(firmwareMax: Float?, model: String) -> FanLimit {
        let ceiling = ceiling(forModel: model)
        let modelKnown = modelCeilings[model] != nil
        let fallback = FanLimit(
            value: ceiling,
            source: modelKnown ? "model ceiling (\(model))" : "absolute ceiling"
        )
        guard let firmwareMax, firmwareMax.isFinite, firmwareMax > 0,
              firmwareMax <= absoluteCeiling else {
            return fallback
        }
        if firmwareMax <= ceiling {
            return FanLimit(value: firmwareMax, source: "firmware F0Mx")
        }
        return fallback
    }
}
