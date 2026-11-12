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

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
