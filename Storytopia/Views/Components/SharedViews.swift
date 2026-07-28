import SwiftUI

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

    var body: some View {
        Button {
        } label: {
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

struct BottomNavigationBar: View {
    @Binding var selectedPage: StoryPage

    var body: some View {
        HStack(spacing: 0) {
            NavItem(
                title: "Home",
                systemName: selectedPage == .home ? "house.fill" : "house",
                isSelected: selectedPage == .home,
                selectedColor: .homeAccent
            ) {
                selectedPage = .home
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
    }
}

struct CreateNavItem: View {
    let isSelected: Bool
    var selectedColor: Color = .storyPurple
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: isSelected ? "plus.circle.fill" : "plus.circle")
                    .font(.system(size: 21, weight: isSelected ? .bold : .regular))

                Text("Create")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(isSelected ? selectedColor : Color.storyInk.opacity(0.82))
            .frame(maxWidth: .infinity)
            .frame(height: 44)
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Create")
    }
}
