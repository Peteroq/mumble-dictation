import OSLog

enum Log {
    static let audio = Logger(subsystem: "ai.pivotstudio.mumble", category: "audio")
    static let speech = Logger(subsystem: "ai.pivotstudio.mumble", category: "speech")
    static let hotkey = Logger(subsystem: "ai.pivotstudio.mumble", category: "hotkey")
    static let inject = Logger(subsystem: "ai.pivotstudio.mumble", category: "inject")
    static let app = Logger(subsystem: "ai.pivotstudio.mumble", category: "app")
}
