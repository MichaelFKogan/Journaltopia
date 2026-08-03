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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authStore)
                .environmentObject(generationCreditStore)
                .onOpenURL { url in
                    authStore.handleOpenURL(url)
                }
        }
    }
}
