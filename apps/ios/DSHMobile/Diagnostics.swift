import Foundation
import OSLog

enum WhaleDiagnostics {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.blackflag0623.dsh"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    static let transport = Logger(subsystem: subsystem, category: "transport")
    static let session = Logger(subsystem: subsystem, category: "session")
    static let interaction = Logger(subsystem: subsystem, category: "interaction")

    static func errorFields(_ error: Error) -> (domain: String, code: Int) {
        let value = error as NSError
        return (value.domain, value.code)
    }

    static func console(_ category: String, _ message: String) {
        NSLog("[WhaleGirl:%@] %@", category, message)
        switch category {
        case "lifecycle":
            lifecycle.notice("\(message, privacy: .public)")
        case "transport":
            transport.notice("\(message, privacy: .public)")
        case "session":
            session.notice("\(message, privacy: .public)")
        case "interaction":
            interaction.notice("\(message, privacy: .public)")
        default:
            app.notice("\(message, privacy: .public)")
        }
    }
}
