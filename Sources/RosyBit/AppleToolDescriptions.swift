import Foundation

/// Tool descriptions written for Apple's on-device model specifically.
///
/// A tool description is prompt engineering, not API documentation, and prompts
/// do not port between models. Rosy already accepts this everywhere else — which
/// tools are advertised at all depends on the runtime, and guided routing is
/// gated to the exact Bonsai build it was measured on. This is the same idea one
/// level down: same tools, same validators, wording tuned to the reader.
///
/// **Why it was needed.** The shared descriptions hedge, because they were
/// written to stop a 1-bit model from muting the Mac unprompted:
///
///     volume_control — "Use only when the user clearly requests the change."
///
/// Bonsai and DeepSeek read that as caution. Apple's model reads it as a reason
/// to reach for the zero-argument getter beside it and then describe the volume
/// it did not change. Measured over five runs per intent against the real schema
/// block, at temperature 0.7:
///
///     intent          shared   here
///     set volume        0/5    5/5
///     read volume       5/5    5/5
///     set timer         5/5    5/5
///     list timers       5/5    5/5
///     alarm at 6:37     0/5    4/5
///     open an app       0/5    5/5
///     ————————————————————————————
///     total            15/30  29/30
///
/// Three things do the work, and they are worth keeping if these are ever
/// rewritten: the action tools stop hedging, the read tools say explicitly what
/// they are *not* for, and `reminders_manage` names "alarm" and "time of day",
/// which is vocabulary Rosy has no other word for.
///
/// **Deliberately sparse.** Only tools that needed changing appear here; every
/// other tool keeps the shared description, and a name that no longer exists is
/// caught by `AppleToolDescriptionTests` rather than rotting quietly.
///
/// Nothing here weakens a guard. The hedges were belt to the validators' braces:
/// every argument still goes through the skill's own parser and bounds check,
/// and that is what actually stands between the model and the Mac.
enum AppleToolDescriptions {

    static let overrides: [String: String] = [
        "volume_get":
            "Read the Mac's current output volume. Use this only when the user asks "
            + "what the volume is or how loud the Mac is. Never use it when the user "
            + "asks for the volume to be changed.",

        "volume_control":
            "Set, mute, or unmute this Mac's output volume. Use this whenever the user "
            + "asks for the volume to change, including any specific percentage. Do not "
            + "read the volume first; this reports the resulting level itself.",

        "timer_list":
            "List the timers Rosy Bit currently has scheduled. Use this only when the "
            + "user asks which timers exist. Never use it to create or cancel one.",

        "timer_manage":
            "Create or cancel a Rosy Bit timer. Use this whenever the user asks for a "
            + "timer, giving the duration in seconds. A timer counts down a length of "
            + "time; it is not a time of day.",

        "reminders_list":
            "List incomplete reminders from Apple Reminders. Use this only when the user "
            + "asks what their reminders are. Never use it to create, complete, or "
            + "delete one.",

        "reminders_manage":
            "Create, complete, or delete an Apple Reminder. Use this whenever the user "
            + "asks for a reminder, an alarm, or to be woken or notified at a particular "
            + "time of day, giving that time as the due date.",

        "apps_find":
            "Find an installed Mac application by name. Use this only when the user asks "
            + "whether an app is installed or what it is called. Never use it to open or "
            + "quit an app.",

        "apps_finder_control":
            "Open or quit an installed app, open a standard Finder folder, or reveal an "
            + "existing path. Use this whenever the user asks for any of those.",
    ]

    /// The description the on-device model should be given for `name`.
    static func description(for name: String, shared: String) -> String {
        overrides[name] ?? shared
    }
}
