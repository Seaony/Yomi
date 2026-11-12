//
//  CodeEdgeApp.swift
//  CodeEdge
//
//  Created by seaony on 2026/8/31.
//

import SwiftUI

@main
enum CodeEdgeLauncher {
    static func main() {
        LegacyMigration.runOnce()
        CodeEdgeApp.main()
    }
}

struct CodeEdgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @Environment(\.openSettings) private var openSettings

    var body: some Scene {
        let _ = appDelegate.configureSettings { openSettings() }
        Settings {
            SettingsView(store: appDelegate.store, updates: appDelegate.updates, navigation: appDelegate.settingsNavigation)
                .background(SettingsWindowRegistration(appDelegate: appDelegate))
                .containerBackground(CodeEdgeSettingsTheme.background, for: .window)
                .onAppear { NSApp.setActivationPolicy(.regular) }
        }
        .windowResizability(.contentSize)
    }
}

// 让设置窗口继续参与常驻应用的前后台切换，窗口尺寸和工具栏交给系统设置场景。
private struct SettingsWindowRegistration: NSViewRepresentable {
    let appDelegate: AppDelegate

    func makeNSView(context: Context) -> RegistrationView {
        RegistrationView(appDelegate: appDelegate)
    }

    func updateNSView(_ nsView: RegistrationView, context: Context) {}

    final class RegistrationView: NSView {
        let appDelegate: AppDelegate

        init(appDelegate: AppDelegate) {
            self.appDelegate = appDelegate
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            appDelegate.registerSettingsWindow(window)
        }
    }
}
