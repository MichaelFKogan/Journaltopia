import SwiftUI

private let isBottomNavigationVisible = true

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
                    .frame(width: 38, height: 38)

                Image(systemName: "plus")
                    .font(.system(size: 25, weight: .regular))
                    .foregroundStyle(Color.white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
        .accessibilityLabel("Create")
    }
}
