import SwiftUI

struct CreateVisualTestView: View {
    @State private var title = "Summer Library Notes"
    @State private var entryText = "The rain made the windows look like watercolor. I found a table near the plants and started sketching a character who keeps small maps in her coat pocket."
    @State private var selectedStyle = "Anime"
    @State private var selectedLayout = "5 Panel"
    @State private var savesDraft = true
    @State private var isPrivate = false

    private let styles = ["Anime", "Graphic Novel", "Manga"]
    private let layouts = ["3 Panel", "5 Panel", "6 Panel"]

    var body: some View {
        ZStack {
            Color.homePageBackground
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard
                    editorCard
                    photoCard
                    styleCard
                    optionsCard
                    actionRow
                }
                .padding(16)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("Create Visual Test")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.homePageBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .preferredColorScheme(.light)
    }

    private var headerCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.homeAccent)
                .frame(width: 42, height: 42)
                .background(Color.homeAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("Create Draft")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.storyInk)

                Text("Visual pass using Cloud Journal Test styling")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.homeMutedText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer()

            Button("Save") {
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.homeAccent)
        }
        .settingsTestCard()
    }

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Story Entry")
                    .font(.system(size: 18, weight: .bold, design: .serif))
                    .foregroundStyle(Color.storyInk)

                Spacer()

                Button {
                } label: {
                    Label("Prompts", systemImage: "lightbulb")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.homeAccent)
                }
                .buttonStyle(.plain)
            }

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 15, weight: .semibold))

            TextEditor(text: $entryText)
                .font(.system(size: 15))
                .foregroundStyle(Color.storyInk)
                .frame(minHeight: 190)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.homeInputGray.opacity(0.78), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 10) {
                compactMetadataButton(systemName: "calendar", title: "Jul 18, 2026")
                compactMetadataButton(systemName: "location", title: "Brooklyn, NY")
            }
        }
        .settingsTestCard()
    }

    private var photoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Reference Photos")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                photoSlot(systemName: "camera.fill", title: "Add")
                photoSlot(systemName: "photo", title: "Slot 2")
                photoSlot(systemName: "photo", title: "Slot 3")
            }

            Text("Photos help guide characters, places, and important objects.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.homeMutedText)
        }
        .settingsTestCard()
    }

    private var styleCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Storyboard Setup")

            VStack(alignment: .leading, spacing: 8) {
                controlLabel("Art Style")
                Picker("Art Style", selection: $selectedStyle) {
                    ForEach(styles, id: \.self) { style in
                        Text(style).tag(style)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 8) {
                controlLabel("Layout")
                Picker("Layout", selection: $selectedLayout) {
                    ForEach(layouts, id: \.self) { layout in
                        Text(layout).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
            }

            HStack(spacing: 10) {
                visualToolButton(systemName: "textformat", title: "Font")
                visualToolButton(systemName: "doc.text", title: "Paper")
                visualToolButton(systemName: "paintpalette", title: "Style")
            }
        }
        .settingsTestCard()
    }

    private var optionsCard: some View {
        VStack(spacing: 0) {
            Toggle(isOn: $savesDraft) {
                optionLabel(systemName: "tray.and.arrow.down", title: "Save as draft", subtitle: "Keep this entry in progress")
            }
            .tint(Color.homeAccent)
            .padding(.bottom, 12)

            Divider()

            Toggle(isOn: $isPrivate) {
                optionLabel(systemName: "lock", title: "Private entry", subtitle: "Only visible to you")
            }
            .tint(Color.homeAccent)
            .padding(.top, 12)
        }
        .settingsTestCard()
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
            } label: {
                Label("Generate", systemImage: "sparkles")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(Color.homeAccent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.storyInk)
                    .frame(width: 42, height: 42)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.homeBorder, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More create options")
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 18, weight: .bold, design: .serif))
            .foregroundStyle(Color.storyInk)
    }

    private func controlLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Color.homeMutedText)
    }

    private func compactMetadataButton(systemName: String, title: String) -> some View {
        Button {
        } label: {
            Label(title, systemImage: systemName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.storyInk.opacity(0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.homeBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func photoSlot(systemName: String, title: String) -> some View {
        Button {
        } label: {
            VStack(spacing: 7) {
                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.homeAccent)

                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.homeMutedText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .background(Color.homeInputGray.opacity(0.78), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.homeBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
        }
        .buttonStyle(.plain)
    }

    private func visualToolButton(systemName: String, title: String) -> some View {
        Button {
        } label: {
            Label(title, systemImage: systemName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.storyInk.opacity(0.82))
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.homeBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func optionLabel(systemName: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.homeAccent)
                .frame(width: 34, height: 34)
                .background(Color.homeAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.storyInk)

                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.homeMutedText)
            }
        }
    }
}

private extension View {
    func settingsTestCard() -> some View {
        self
            .padding(14)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.homeBorder, lineWidth: 1)
            )
    }
}
