import SwiftUI
import UIKit

enum DSHStyle {
    static let accent = Color(red: 0.10, green: 0.82, blue: 0.96)
    static let action = Color(red: 0.06, green: 0.38, blue: 0.84)
    static let success = Color(red: 0.12, green: 0.76, blue: 0.72)
    static let warning = Color(red: 1.00, green: 0.67, blue: 0.24)
    static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.008, green: 0.035, blue: 0.095, alpha: 1)
            : UIColor(red: 0.91, green: 0.97, blue: 0.995, alpha: 1)
    })
    static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.025, green: 0.105, blue: 0.23, alpha: 1)
            : UIColor(red: 0.975, green: 0.995, blue: 1, alpha: 1)
    })
    static let raised = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.035, green: 0.16, blue: 0.32, alpha: 1)
            : UIColor(red: 0.84, green: 0.95, blue: 1, alpha: 1)
    })
    static let border = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.12, green: 0.69, blue: 0.94, alpha: 0.28)
            : UIColor(red: 0.05, green: 0.48, blue: 0.82, alpha: 0.18)
    })

    static var oceanGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.01, green: 0.12, blue: 0.32),
                Color(red: 0.02, green: 0.36, blue: 0.68),
                Color(red: 0.08, green: 0.78, blue: 0.91)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

@main
struct WhaleGirlApp: App {
    @State private var store = AppStore()
    @AppStorage("hostURL") private var hostURL = ""
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(store: store, hostURL: $hostURL)
                .tint(DSHStyle.accent)
                .task {
                    #if DEBUG
                    UIApplication.shared.isIdleTimerDisabled = true
                    WhaleDiagnostics.app.debug("Debug idle timer disabled")
                    #endif
                }
                .onChange(of: scenePhase) { _, phase in
                    WhaleDiagnostics.lifecycle.debug(
                        "scene phase changed value=\(String(describing: phase), privacy: .public)"
                    )
                    WhaleDiagnostics.console(
                        "lifecycle",
                        "scene phase \(String(describing: phase))"
                    )
                    switch phase {
                    case .active:
                        store.applicationDidBecomeActive()
                    case .background:
                        store.applicationDidEnterBackground()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}
