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
        #if DEBUG
        print("[WhaleGirl:\(category)] \(message)")
        #endif
    }
}
