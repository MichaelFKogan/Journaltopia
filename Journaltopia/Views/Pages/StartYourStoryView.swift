import SwiftUI

/// The account-start page.
///
/// It is the sign-in page wearing its create-account half: same hero video, same panel, same
/// providers and email fields. Two things are its own — the heading stays "Start your story" through
/// both halves of the toggle, and the way out of the page leads *into* Journaltopia rather than back
/// to wherever the visitor came from.
struct StartYourStoryView: View {
    @EnvironmentObject private var authStore: SupabaseAuthStore
    @Environment(\.dismiss) private var dismiss

    let onExploreFirst: (() -> Void)?
    let onAuthenticated: (() -> Void)?

    init(
        onExploreFirst: (() -> Void)? = nil,
        onAuthenticated: (() -> Void)? = nil
    ) {
        self.onExploreFirst = onExploreFirst
        self.onAuthenticated = onAuthenticated
    }

    var body: some View {
        SignInView(
            promptTitle: "Start your story",
            promptSubtitle: "Create a free account to start writing and keep your journals and stories synced across your devices.",
            startsCreatingAccount: true,
            keepsPromptCopy: true,
            // The page is reached by swiping onboarding or by pushing it, both of which already have
            // a way back. A close button here would only compete with them.
            showsDismissButton: false,
            // Providers first: the three ways in read as one list, and the fields unfold only for
            // the visitor who picks email.
            foldsEmailBehindButton: true,
            continueBrowsingTitle: "Continue To Journaltopia",
            continueBrowsingSystemImage: "arrow.right",
            onContinueBrowsing: continueToJournaltopia
        )
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: authStore.status) { status in
            // The account arrives through `authStateChanges`, so this is the signal that the page is
            // done — not the provider call returning.
            if status == .signedIn {
                onAuthenticated?()
            }
        }
    }

    private func continueToJournaltopia() {
        if let onExploreFirst {
            onExploreFirst()
        } else {
            dismiss()
        }
    }
}

#Preview {
    NavigationStack {
        StartYourStoryView()
            .environmentObject(SupabaseAuthStore.preview(status: .signedOut))
    }
}
