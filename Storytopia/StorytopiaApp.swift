//
//  StorytopiaApp.swift
//  Storytopia
//
//  Created by Mike Kogan on 5/28/26.
//

import SwiftUI

@main
struct StorytopiaApp: App {
    @StateObject private var authStore = SupabaseAuthStore()
    @StateObject private var generationCreditStore = GenerationCreditStore()
    /// Owned by the app rather than by a screen: a storyboard generation outlives whatever view
    /// started it, so the thing watching for it has to outlive that view too.
    @StateObject private var pendingStoryboardMonitor = PendingStoryboardGenerationMonitor()
    /// One gate for the whole app rather than an alert per screen, so every account-required action
    /// refuses the same way and the sheet can be mounted once at the root.
    @StateObject private var signInGate = SignInGate()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authStore)
                .environmentObject(generationCreditStore)
                .environmentObject(pendingStoryboardMonitor)
                .environmentObject(signInGate)
                .onOpenURL { url in
                    authStore.handleOpenURL(url)
                }
        }
    }
}
