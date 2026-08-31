//
//  YomiApp.swift
//  Yomi
//
//  Created by seaony on 2026/8/31.
//

import SwiftUI

@main
struct YomiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
