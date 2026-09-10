import Foundation

/// User-controlled native capabilities exposed to Rosy's own conversations.
///
/// These switches govern the whole capability, not merely whether its schema
/// is advertised. That distinction matters for deterministic volume commands:
/// a skill shown as off must not retain a hidden route that can mutate the Mac.
enum RosySkill: String, CaseIterable, Identifiable {
    case dictionary
    case volumeControl
    case calculatorUnits
    case timers
    case batterySystem
    case appsFinder
    case fileSearch
    case reminders
    case webSearch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictionary: return "Dictionary"
        case .volumeControl: return "Volume Control"
        case .calculatorUnits: return "Calculator & Units"
        case .timers: return "Timers"
        case .batterySystem: return "Battery & System"
        case .appsFinder: return "Apps & Finder"
        case .fileSearch: return "File Search"
        case .reminders: return "Reminders"
        case .webSearch: return "Web Search (Kagi)"
        }
    }

    /// Every native skill reads this Mac and defaults to on. Web Search does
    /// not: it is the only capability that sends a question off the machine,
    /// to a third party, for money. A capability with that shape is opted
    /// into deliberately or it is not enabled at all.
    var defaultsToEnabled: Bool {
        self != .webSearch
    }

    var defaultsKey: String {
        switch self {
        case .dictionary: return "dictionarySkillEnabled"
        case .volumeControl: return "volumeControlSkillEnabled"
        case .calculatorUnits: return "calculatorUnitsSkillEnabled"
        case .timers: return "timersSkillEnabled"
        case .batterySystem: return "batterySystemSkillEnabled"
        case .appsFinder: return "appsFinderSkillEnabled"
        case .fileSearch: return "fileSearchSkillEnabled"
        case .reminders: return "remindersSkillEnabled"
        case .webSearch: return "webSearchSkillEnabled"
        }
    }
}

enum SkillSettings {
    enum RoutingMode: String, CaseIterable {
        case guided
        case modelLed

        var title: String {
            switch self {
            case .guided: return "Guided"
            case .modelLed: return "Model-led"
            }
        }
    }

    private static let routingModeKey = "toolRoutingMode"

    static func routingMode(defaults: UserDefaults = .standard) -> RoutingMode {
        defaults.string(forKey: routingModeKey).flatMap(RoutingMode.init(rawValue:)) ?? .guided
    }

    static func setRoutingMode(_ mode: RoutingMode, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: routingModeKey)
    }

    static func isEnabled(
        _ skill: RosySkill,
        defaults: UserDefaults = .standard
    ) -> Bool {
        (defaults.object(forKey: skill.defaultsKey) as? Bool) ?? skill.defaultsToEnabled
    }

    static func setEnabled(
        _ enabled: Bool,
        for skill: RosySkill,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(enabled, forKey: skill.defaultsKey)
    }

    /// The canonical schema list for one request. Cloud providers can use the
    /// measured native loop directly, and so can Apple's on-device model, whose
    /// tool calling is a first-class framework feature rather than something
    /// coaxed out of a prompt. Guided local routing remains gated to the exact
    /// Bonsai build that passed the harness; explicitly selecting Model-led is
    /// the user's opt-in for other, typically larger, local models.
    static func schemas(
        isCloud: Bool,
        modelName: String?,
        isAppleFoundationModel: Bool = false,
        dictionaryEnabled: Bool? = nil,
        volumeEnabled: Bool? = nil,
        calculatorEnabled: Bool? = nil,
        timersEnabled: Bool? = nil,
        systemEnabled: Bool? = nil,
        appsFinderEnabled: Bool? = nil,
        fileSearchEnabled: Bool? = nil,
        remindersEnabled: Bool? = nil,
        webSearchEnabled: Bool? = nil,
        routingMode selectedRoutingMode: RoutingMode? = nil
    ) -> [[String: Any]] {
        let mode = selectedRoutingMode ?? routingMode()
        let runtimeSupportsTools = isCloud
            || isAppleFoundationModel
            || DictionaryTool.isAvailable(for: modelName)
            || mode == .modelLed
        guard runtimeSupportsTools else { return [] }

        var result: [[String: Any]] = []
        if dictionaryEnabled ?? isEnabled(.dictionary) {
            result += DictionaryTool.schema
        }
        if volumeEnabled ?? isEnabled(.volumeControl) {
            result += VolumeTool.schema
        }
        if calculatorEnabled ?? isEnabled(.calculatorUnits) {
            result += CalculatorTool.schema
        }
        if timersEnabled ?? isEnabled(.timers) {
            result += TimerTool.schema
        }
        if systemEnabled ?? isEnabled(.batterySystem) {
            result += SystemStatusTool.schema
        }
        if appsFinderEnabled ?? isEnabled(.appsFinder) {
            result += AppsFinderTool.schema
        }
        if fileSearchEnabled ?? isEnabled(.fileSearch) {
            result += FileSearchTool.schema
        }
        if remindersEnabled ?? isEnabled(.reminders) {
            result += RemindersTool.schema
        }
        // Advertised only when a key actually exists. A schema Rosy cannot
        // honour costs prefix tokens on every request and invites the model
        // to promise a search that will only ever return an error.
        if webSearchEnabled ?? (isEnabled(.webSearch) && KagiCredentialStore.hasKey) {
            result += KagiTool.schema
        }
        if mode == .modelLed {
            result += ModelLedActionTool.schemas(
                volumeEnabled: volumeEnabled ?? isEnabled(.volumeControl),
                timersEnabled: timersEnabled ?? isEnabled(.timers),
                appsFinderEnabled: appsFinderEnabled ?? isEnabled(.appsFinder),
                remindersEnabled: remindersEnabled ?? isEnabled(.reminders))
        }
        return result
    }
}
