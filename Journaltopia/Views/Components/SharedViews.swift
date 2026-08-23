import SwiftUI

private let isBottomNavigationVisible = true

/// Width-to-height ratio shared by every journal cover and entry preview card.
///
/// Covers and entry pages sit side by side on Home, in the Journals grid, and in a journal's Pages
/// tab, so they are laid out from one number rather than each surface picking its own.
enum JournalPaperGeometry {
    static let aspectRatio: CGFloat = 0.72
}

struct WatercolorPaperPageBackground: View {
    static let assetName = "watercolor-paper"

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.homePageBackground

                Image(Self.assetName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

struct SectionTitle: View {
    let title: String
    let action: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 18, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk)

            Spacer()

            Button(action) {
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.storyPurple)
        }
        .padding(.horizontal, 2)
    }
}

struct CircleIconButton: View {
    let systemName: String
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.storyInk)
                .frame(width: 42, height: 42)
                .background(Color.storySoftPink, in: Circle())
        }
    }
}

struct HeaderIconButton: View {
    let systemName: String
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Color.storyInk)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
    }
}

struct ProfilePlaceholder: View {
    var size: CGFloat = 42

    var body: some View {
        Image("art_style_anime")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(Color.storyInk.opacity(0.08), lineWidth: 1)
            )
    }
}

/// The compact upgrade affordance, shown where a credit balance would be misleading.
///
/// Deliberately small: this appears in a toolbar next to someone's journal, and monetization that
/// shouts there is worse than monetization that waits.
struct JournaltopiaPlusPill: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "crown.fill")
                .font(.system(size: 11, weight: .bold))

            Text("Upgrade")
                .font(.system(size: 12, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .fixedSize(horizontal: true, vertical: false)
        .background(Color.storyPurple, in: Capsule())
    }
}

struct CreditBalanceBadge: View {
    let balance: Int?
    var isRefreshing = false
    var foregroundColor = Color.storyInk
    var accentColor = Color.storyPurple

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(accentColor)
                .frame(width: 19, height: 19)
                .background(accentColor.opacity(0.12), in: Circle())

            if isRefreshing && balance == nil {
                ProgressView()
                    .controlSize(.mini)
                    .tint(accentColor)
            } else {
                Text(balance.map(String.init) ?? "-")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(foregroundColor)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .fixedSize(horizontal: true, vertical: false)
        .background(Color.white.opacity(0.86), in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.storyBorder.opacity(0.58), lineWidth: 1)
        )
        .accessibilityLabel("Generation credits")
        .accessibilityValue(balance.map { "\($0) credits" } ?? "Loading")
    }
}

/// Where the floating controls sit above the tab bar, and how much room the scroll content has to
/// leave underneath so its last row is not left permanently hidden behind them.
enum JournaltopiaFloatingControlMetrics {
    static let bottomInset: CGFloat = 84
    static let floatingButtonDiameter: CGFloat = 60
    static let signInCalloutHeight: CGFloat = 44

    /// The callout shares a row with the floating button but is the shorter of the two, so matching
    /// their bottom edges leaves them looking misaligned. Lifting it by half the height difference
    /// puts the two centre lines together instead.
    static let signInCalloutBottomInset: CGFloat =
        bottomInset + (floatingButtonDiameter - signInCalloutHeight) / 2

    /// What the scroll content adds underneath so its last row clears the callout. The floating
    /// button reaches further down the screen than this but sits against the trailing edge, where
    /// it covers a corner rather than a whole row.
    static let signInCalloutContentInset: CGFloat = 32
}

/// The one call to action on the signed-out browse screens, floating at the bottom centre above the
/// tab bar.
///
/// The sample badges say *what* this content is; this says what to do about it. It routes through
/// ``SignInGate`` rather than presenting `SignInView` itself so the sign-in page is still the single
/// one mounted at the app root, and so a visitor who signs in from here lands back where they were.
///
/// The label is kept short on purpose. Centred, it shares a row with a floating button pinned 20pt
/// from the trailing edge, so the pill has about 205pt to live in before the two touch on a 375pt
/// phone — a longer sentence collides there while still looking fine on a Pro.
struct SampleSignInCallout: View {
    @EnvironmentObject private var signInGate: SignInGate

    var body: some View {
        Button {
            signInGate.requireAccount(for: .signIn)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .bold))

                Text("Sign in to start")
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 18)
            .frame(height: JournaltopiaFloatingControlMetrics.signInCalloutHeight)
            .background(Color.storyPurple, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
            )
            // It floats over the content rather than sitting in the layout, so it carries its own
            // separation from whatever scrolls underneath it.
            .shadow(color: Color.black.opacity(0.28), radius: 14, y: 6)
            .shadow(color: Color.storyPurple.opacity(0.34), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sign in to start")
        .accessibilityHint("Opens the sign in page")
    }
}

struct BottomNavigationBar: View {
    @Binding var selectedPage: StoryPage

    @ViewBuilder
    var body: some View {
        if isBottomNavigationVisible {
            HStack(spacing: 0) {
                NavItem(
                    title: "Home",
                    systemName: selectedPage == .home ? "house.fill" : "house",
                    isSelected: selectedPage == .home,
                    selectedColor: .homeAccent
                ) {
                    selectedPage = .home
                }
                NavItem(
                    title: "Entries",
                    systemName: selectedPage == .entries ? "doc.text.fill" : "doc.text",
                    isSelected: selectedPage == .entries,
                    selectedColor: .homeAccent
                ) {
                    selectedPage = .entries
                }
                CreateNavItem(isSelected: selectedPage == .create, selectedColor: .homeAccent) {
                    withAnimation(.snappy(duration: 0.32)) {
                        selectedPage = .create
                    }
                }
                NavItem(
                    title: "Journals",
                    systemName: selectedPage == .journal ? "book.closed.fill" : "book.closed",
                    isSelected: selectedPage == .journal,
                    selectedColor: .homeAccent
                ) {
                    selectedPage = .journal
                }
                NavItem(
                    title: "Profile",
                    systemName: selectedPage == .profile ? "person.fill" : "person",
                    isSelected: selectedPage == .profile,
                    selectedColor: .homeAccent
                ) {
                    selectedPage = .profile
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)
            .padding(.bottom, 0)
            .background(Color.white)
            .overlay(
                Rectangle()
                    .fill(Color.homeBorder)
                    .frame(height: 1),
                alignment: .top
            )
            .transaction { transaction in
                transaction.animation = nil
            }
        }
    }
}

struct NavItem: View {
    let title: String
    let systemName: String
    let isSelected: Bool
    var selectedColor: Color = .storyPurple
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 21, weight: isSelected ? .bold : .regular))

                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(isSelected ? selectedColor : Color.storyInk.opacity(0.82))
            .frame(maxWidth: .infinity)
            .frame(height: 44)
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
    }
}

struct CreateNavItem: View {
    let isSelected: Bool
    var selectedColor: Color = .storyPurple
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(selectedColor)
                    .frame(width: 46, height: 46)

                Image(systemName: "plus")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(Color.white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
        .accessibilityLabel("Create")
    }
}
