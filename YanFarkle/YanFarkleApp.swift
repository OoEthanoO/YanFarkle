//
//  Farkle_AppleApp.swift
//  Farkle Apple
//
//  Created by Yan Xu on 2026-04-04.
//

import SwiftUI

#if os(macOS)
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
#endif

@main
struct YanFarkleApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif
    
    @Environment(\.scenePhase) private var scenePhase
    
    #if os(iOS)
    @State private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    var body: some Scene {
        let windowGroup = WindowGroup {
            ContentView()
                .onChangeWithBackwardCompatibility(of: scenePhase) { newPhase in
                    #if os(iOS)
                    if newPhase == .background {
                        backgroundTask = UIApplication.shared.beginBackgroundTask {
                            if backgroundTask != .invalid {
                                UIApplication.shared.endBackgroundTask(backgroundTask)
                                backgroundTask = .invalid
                            }
                        }
                    } else if newPhase == .active {
                        if backgroundTask != .invalid {
                            UIApplication.shared.endBackgroundTask(backgroundTask)
                            backgroundTask = .invalid
                        }
                    }
                    #endif
                }
        }

        #if os(macOS)
        windowGroup.windowResizability(.contentSize)
        #else
        windowGroup
        #endif
    }
}
