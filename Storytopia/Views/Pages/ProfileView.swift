import SwiftUI
import UIKit

struct ProfileView: View {
    @EnvironmentObject private var authStore: SupabaseAuthStore
    @EnvironmentObject private var generationCreditStore: GenerationCreditStore

    @Binding var selectedPage: StoryPage
    @Binding var generatedStoryboards: [GeneratedStoryboard]
    var embedsInNavigationStack = true

    @State private var selectedStoryboardIndex: Int?
    @State private var isSelecting = false
    @State private var selectedStoryboardIDs: Set<UUID> = []
    @State private var storyboardsToShare: [GeneratedStoryboard] = []
    @State private var isShowingShareSheet = false
    @State private var isLoadingProfileStoryboards = false
    @State private var isLoadingMoreProfileStoryboards = false
    @State private var hasMoreProfileStoryboards = true
    @State private var nextProfileStoryboardOffset = 0
    @State private var profileStoryboardErrorMessage: String?
    private let profileStoryboardPageSize = 9

    private let storyboardColumns = [
        GridItem(.flexible(), spacing: 1),
        GridItem(.flexible(), spacing: 1),
        GridItem(.flexible(), spacing: 1)
    ]

    var body: some View {
        wrappedProfileContent
        .fullScreenCover(
            isPresented: Binding(
                get: { selectedStoryboardIndex != nil },
                set: { isPresented in
                    if !isPresented {
                        selectedStoryboardIndex = nil
                    }
                }
            )
        ) {
            if let selectedStoryboardIndex {
                StoryboardImageViewer(
                    storyboards: generatedStoryboards,
                    initialIndex: selectedStoryboardIndex
                )
                .presentationBackground(.clear)
            }
        }
        .sheet(isPresented: $isShowingShareSheet) {
            ActivityView(activityItems: storyboardsToShare.map(\.image))
                .presentationDetents([.medium, .large])
        }
        .onChange(of: generatedStoryboards.map(\.id)) { availableIDs in
            selectedStoryboardIDs.formIntersection(Set(availableIDs))

            if generatedStoryboards.isEmpty {
                endSelection()
            }
        }
        .task(id: authStore.userID) {
            await loadProfileStoryboards()
            await generationCreditStore.refresh(isSignedIn: authStore.userID != nil)
        }
    }

    @ViewBuilder
    private var wrappedProfileContent: some View {
        if embedsInNavigationStack {
            NavigationStack {
                profileContent
                    .toolbar(.hidden, for: .navigationBar)
            }
        } else {
            profileContent
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .toolbarBackground(Color.homePageBackground, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text("Profile")
                            .font(.system(size: 24, weight: .bold, design: .serif))
                            .foregroundStyle(Color.storyInk)
                    }

                    ToolbarItem(placement: .navigationBarTrailing) {
                        settingsButton
                    }
                }
        }
    }

    private var profileContent: some View {
        ZStack(alignment: .bottom) {
            Color.homePageBackground
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    if embedsInNavigationStack {
                        header
                    }

                    profileSummary
                    storyboardsSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, isSelecting ? 150 : 96)
            }

            VStack(spacing: 0) {
                if isSelecting {
                    selectionActionBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                BottomNavigationBar(selectedPage: $selectedPage)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("Profile")
                .font(.system(size: 24, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk)

            Spacer()

            CreditBalanceBadge(
                balance: generationCreditStore.balance,
                isRefreshing: generationCreditStore.isRefreshing
            )

            settingsButton
        }
        .padding(.top, 2)
    }

    private var settingsButton: some View {
        NavigationLink {
            SettingsView(selectedPage: $selectedPage)
                .enableInteractivePopGesture()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.storyInk.opacity(0.65))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open settings")
    }

    private var profileSummary: some View {
        VStack(spacing: 18) {
            HStack(alignment: .center, spacing: 18) {
                ProfilePlaceholder(size: 82)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Story Seeker")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(Color.storyInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Text("@story.seeker")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.storyInk.opacity(0.7))

                    Text("Collecting life's moments,\none storyboard at a time.")
                        .font(.system(size: 14, weight: .medium))
                        .lineSpacing(2)
                        .foregroundStyle(Color.storyInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 0) {
                ProfileStat(value: "\(generatedStoryboards.count)", title: "Storyboards")
                ProfileStat(value: "\(thisMonthStoryboardCount)", title: "This Month")
                ProfileStat(value: generationCreditBalanceText, title: "Credits")
                ProfileStat(value: "0", title: "Day Streak")
            }
        }
        .padding(.top, 2)
    }

    private var generationCreditBalanceText: String {
        generationCreditStore.balance.map(String.init) ?? "-"
    }

    private var thisMonthStoryboardCount: Int {
        let calendar = Calendar.current
        guard let month = calendar.dateInterval(of: .month, for: Date()) else {
            return 0
        }

        return generatedStoryboards.filter { month.contains($0.createdAt) }.count
    }

    private var storyboardsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your Storyboards")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(Color.storyInk)

                    Text("All the storyboards you've created.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.homeMutedText)
                }

                Spacer()

                if !generatedStoryboards.isEmpty && !isLoadingProfileStoryboards {
                    Button {
                        withAnimation(.snappy(duration: 0.24)) {
                            if isSelecting {
                                endSelection()
                            } else {
                                isSelecting = true
                            }
                        }
                    } label: {
                        Text(isSelecting ? "Done" : "Select")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.homeAccent)
                            .frame(height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(isSelecting ? "Ends storyboard selection" : "Selects multiple storyboards")
                }
            }

            if isLoadingProfileStoryboards && generatedStoryboards.isEmpty {
                LazyVGrid(columns: storyboardColumns, spacing: 1) {
                    ForEach(0..<9, id: \.self) { _ in
                        LoadingStoryboardCard()
                    }
                }
            } else if let profileStoryboardErrorMessage {
                ProfileStoryboardErrorState(message: profileStoryboardErrorMessage) {
                    Task {
                        await loadProfileStoryboards(forceReload: true)
                    }
                }
            } else if generatedStoryboards.isEmpty {
                LazyVGrid(columns: storyboardColumns, spacing: 1) {
                    ForEach(0..<9, id: \.self) { _ in
                        StoryboardPlaceholderCard()
                    }
                }
            } else {
                LazyVGrid(columns: storyboardColumns, spacing: 1) {
                    ForEach(Array(generatedStoryboards.enumerated()), id: \.element.id) { index, storyboard in
                        Button {
                            if isSelecting {
                                toggleSelection(for: storyboard)
                            } else {
                                selectedStoryboardIndex = index
                            }
                        } label: {
                            GeneratedStoryboardThumbnail(
                                storyboard: storyboard,
                                isSelecting: isSelecting,
                                isSelected: selectedStoryboardIDs.contains(storyboard.id)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            isSelecting
                                ? "\(selectedStoryboardIDs.contains(storyboard.id) ? "Selected" : "Not selected") storyboard"
                                : "Open storyboard"
                        )
                        .accessibilityAddTraits(
                            selectedStoryboardIDs.contains(storyboard.id) ? .isSelected : []
                        )
                        .onAppear {
                            loadMoreProfileStoryboardsIfNeeded(currentIndex: index)
                        }
                    }

                    if isLoadingMoreProfileStoryboards {
                        ForEach(0..<3, id: \.self) { _ in
                            LoadingStoryboardCard()
                        }
                    }
                }
            }
        }
    }

    private var selectedStoryboards: [GeneratedStoryboard] {
        generatedStoryboards.filter { selectedStoryboardIDs.contains($0.id) }
    }

    private var areAllStoryboardsSelected: Bool {
        !generatedStoryboards.isEmpty && selectedStoryboardIDs.count == generatedStoryboards.count
    }

    private var selectionActionBar: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    if areAllStoryboardsSelected {
                        selectedStoryboardIDs.removeAll()
                    } else {
                        selectedStoryboardIDs = Set(generatedStoryboards.map(\.id))
                    }
                }
            } label: {
                Label(
                    areAllStoryboardsSelected ? "Deselect All" : "Select All",
                    systemImage: areAllStoryboardsSelected ? "checkmark.circle.fill" : "checkmark.circle"
                )
            }
            .selectionActionStyle()

            Spacer(minLength: 4)

            Button {
                storyboardsToShare = selectedStoryboards
                isShowingShareSheet = true
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .selectionActionStyle()
            .disabled(selectedStoryboardIDs.isEmpty)
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.homeBorder)
                .frame(height: 1)
        }
    }

    private func toggleSelection(for storyboard: GeneratedStoryboard) {
        withAnimation(.snappy(duration: 0.18)) {
            if selectedStoryboardIDs.contains(storyboard.id) {
                selectedStoryboardIDs.remove(storyboard.id)
            } else {
                selectedStoryboardIDs.insert(storyboard.id)
            }
        }
    }

    @MainActor
    private func loadProfileStoryboards(forceReload: Bool = false) async {
        guard authStore.userID != nil else {
            generatedStoryboards = []
            profileStoryboardErrorMessage = nil
            isLoadingProfileStoryboards = false
            return
        }

        let cachedStoryboards = Array(GeneratedStoryboardStore.load().prefix(profileStoryboardPageSize))
        if !forceReload, !cachedStoryboards.isEmpty {
            generatedStoryboards = cachedStoryboards
            profileStoryboardErrorMessage = nil
            isLoadingProfileStoryboards = false
            nextProfileStoryboardOffset = cachedStoryboards.count
            hasMoreProfileStoryboards = true
            return
        }

        isLoadingProfileStoryboards = true
        isLoadingMoreProfileStoryboards = false
        hasMoreProfileStoryboards = true
        nextProfileStoryboardOffset = 0
        profileStoryboardErrorMessage = nil
        defer { isLoadingProfileStoryboards = false }

        do {
            let service = SupabaseStoryboardService()
            generatedStoryboards = try await service.loadCompletedJournalStoryboardImages(
                limit: profileStoryboardPageSize,
                offset: 0
            )
            nextProfileStoryboardOffset = generatedStoryboards.count
            hasMoreProfileStoryboards = generatedStoryboards.count == profileStoryboardPageSize
            profileStoryboardErrorMessage = nil
        } catch {
            generatedStoryboards = []
            hasMoreProfileStoryboards = false
            print("[Storytopia] Profile storyboard grid load failed: \(error.localizedDescription)")
            profileStoryboardErrorMessage = "Could not load your completed AI storyboards from Storytopia cloud."
        }
    }

    private func loadMoreProfileStoryboardsIfNeeded(currentIndex: Int) {
        guard currentIndex >= generatedStoryboards.count - 3 else {
            return
        }
        guard hasMoreProfileStoryboards, !isLoadingProfileStoryboards, !isLoadingMoreProfileStoryboards else {
            return
        }

        Task {
            await loadMoreProfileStoryboards()
        }
    }

    @MainActor
    private func loadMoreProfileStoryboards() async {
        guard authStore.userID != nil else {
            return
        }
        guard hasMoreProfileStoryboards, !isLoadingProfileStoryboards, !isLoadingMoreProfileStoryboards else {
            return
        }

        let cachedStoryboards = GeneratedStoryboardStore.load()
        if cachedStoryboards.count > generatedStoryboards.count {
            let nextCachedPage = Array(cachedStoryboards.dropFirst(generatedStoryboards.count).prefix(profileStoryboardPageSize))
            generatedStoryboards.append(contentsOf: nextCachedPage)
            nextProfileStoryboardOffset = generatedStoryboards.count
            hasMoreProfileStoryboards = true
            return
        }

        isLoadingMoreProfileStoryboards = true
        defer { isLoadingMoreProfileStoryboards = false }

        do {
            let service = SupabaseStoryboardService()
            let page = try await service.loadCompletedJournalStoryboardImages(
                limit: profileStoryboardPageSize,
                offset: nextProfileStoryboardOffset
            )
            let existingIDs = Set(generatedStoryboards.map(\.id))
            let newStoryboards = page.filter { !existingIDs.contains($0.id) }
            generatedStoryboards.append(contentsOf: newStoryboards)
            nextProfileStoryboardOffset += page.count
            hasMoreProfileStoryboards = page.count == profileStoryboardPageSize
            profileStoryboardErrorMessage = nil
        } catch {
            profileStoryboardErrorMessage = "Could not load more storyboards."
        }
    }

    private func endSelection() {
        isSelecting = false
        selectedStoryboardIDs.removeAll()
    }
}

struct ProfileStat: View {
    let value: String
    let title: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.storyInk)

            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.homeMutedText)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity)
    }
}

struct StoryboardPlaceholderCard: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.white)
                .overlay(
                    Rectangle()
                        .stroke(Color.homeBorder, lineWidth: 1)
                )

            VStack(spacing: 9) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "photo")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(Color.homeAccent.opacity(0.28))

                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.homeAccent.opacity(0.38))
                        .offset(x: 13, y: -8)
                }

                Text("No storyboards yet")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.homeMutedText.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(0.72, contentMode: .fit)
    }
}

struct LoadingStoryboardCard: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.white)
                .overlay(
                    Rectangle()
                        .stroke(Color.homeBorder, lineWidth: 1)
                )

            ProgressView()
                .tint(Color.homeAccent)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(0.72, contentMode: .fit)
    }
}

struct ProfileStoryboardErrorState: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.homeAccent.opacity(0.7))

            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.homeMutedText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Try Again", action: retry)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.homeAccent)
                .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .padding(.horizontal, 16)
        .background(Color.white)
        .overlay(
            Rectangle()
                .stroke(Color.homeBorder, lineWidth: 1)
        )
    }
}

struct GeneratedStoryboardThumbnail: View {
    let storyboard: GeneratedStoryboard
    var isSelecting = false
    var isSelected = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                Image(uiImage: storyboard.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                if isSelecting {
                    Color.black
                        .opacity(isSelected ? 0.18 : 0.04)

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.homeAccent : .white)
                        .background(
                            Circle()
                                .fill(isSelected ? Color.white : Color.black.opacity(0.28))
                                .padding(2)
                        )
                        .shadow(color: .black.opacity(0.24), radius: 2, y: 1)
                        .padding(8)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(0.72, contentMode: .fit)
        .clipped()
        .contentShape(Rectangle())
        .overlay {
            if isSelected {
                Rectangle()
                    .stroke(Color.homeAccent, lineWidth: 3)
            }
        }
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {
    }
}

private extension View {
    func selectionActionStyle(color: Color = .storyInk) -> some View {
        self
            .foregroundStyle(color)
            .padding(.horizontal, 11)
            .frame(height: 38)
            .background(Color.white, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.homeBorder, lineWidth: 1)
            }
    }
}

struct StoryboardImageViewer: View {
    let storyboards: [GeneratedStoryboard]
    let initialIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var visibleIndex: Int

    init(storyboards: [GeneratedStoryboard], initialIndex: Int) {
        self.storyboards = storyboards
        self.initialIndex = initialIndex
        _visibleIndex = State(initialValue: initialIndex)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.storyInk
                .ignoresSafeArea()

            ZoomableVerticalStoryboardView(
                images: storyboards.map(\.image),
                initialIndex: initialIndex,
                visibleIndex: $visibleIndex
            )
            .background(Color.black)

            HStack {
                Text("\(visibleIndex + 1) of \(storyboards.count)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(.black.opacity(0.62), in: Capsule())

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.62), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close storyboard viewer")
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
    }
}

private struct ZoomableVerticalStoryboardView: UIViewRepresentable {
    let images: [UIImage]
    let initialIndex: Int
    @Binding var visibleIndex: Int
    private let topOverlayClearance: CGFloat = 64

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .black
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false

        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])

        context.coordinator.stackView = stackView
        context.coordinator.imageViews = images.enumerated().map { index, image in
            if index == 0 {
                let spacer = UIView()
                spacer.backgroundColor = .black
                spacer.translatesAutoresizingMaskIntoConstraints = false
                spacer.heightAnchor.constraint(equalToConstant: topOverlayClearance).isActive = true
                stackView.addArrangedSubview(spacer)
            }

            if index > 0 {
                stackView.addArrangedSubview(
                    makeImageBoundary(nextIndex: index, totalCount: images.count)
                )
            }

            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleAspectFit
            imageView.backgroundColor = .black
            imageView.clipsToBounds = true
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.heightAnchor.constraint(
                equalTo: imageView.widthAnchor,
                multiplier: image.size.height / max(image.size.width, 1)
            ).isActive = true
            stackView.addArrangedSubview(imageView)
            return imageView
        }

        DispatchQueue.main.async {
            context.coordinator.scrollToInitialImage(in: scrollView)
        }

        return scrollView
    }

    private func makeImageBoundary(nextIndex _: Int, totalCount _: Int) -> UIView {
        let container = UIView()
        container.backgroundColor = UIColor(white: 0.035, alpha: 1)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(equalToConstant: 29).isActive = true

        return container
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableVerticalStoryboardView
        weak var stackView: UIStackView?
        var imageViews: [UIImageView] = []
        private var didScrollToInitialImage = false

        init(parent: ZoomableVerticalStoryboardView) {
            self.parent = parent
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            stackView
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            updateVisibleIndex(in: scrollView)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            updateVisibleIndex(in: scrollView)
        }

        func scrollToInitialImage(in scrollView: UIScrollView) {
            guard
                !didScrollToInitialImage,
                imageViews.indices.contains(parent.initialIndex)
            else {
                return
            }

            scrollView.layoutIfNeeded()
            stackView?.layoutIfNeeded()

            let imageView = imageViews[parent.initialIndex]
            let targetY = max(
                0,
                imageView.frame.midY - (scrollView.bounds.height / 2)
            )
            scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
            didScrollToInitialImage = true
            updateVisibleIndex(in: scrollView)
        }

        private func updateVisibleIndex(in scrollView: UIScrollView) {
            guard !imageViews.isEmpty else {
                return
            }

            let viewportCenterY = scrollView.contentOffset.y + (scrollView.bounds.height / 2)
            let zoomScale = scrollView.zoomScale
            let closestIndex = imageViews.indices.min { left, right in
                abs((imageViews[left].frame.midY * zoomScale) - viewportCenterY)
                    < abs((imageViews[right].frame.midY * zoomScale) - viewportCenterY)
            }

            guard
                let closestIndex,
                closestIndex != parent.visibleIndex
            else {
                return
            }

            parent.visibleIndex = closestIndex
        }
    }
}

private struct LegacyStoryboardImageViewer: View {
    let storyboard: GeneratedStoryboard

    @Environment(\.dismiss) private var dismiss
    @State private var imageScale: CGFloat = 1
    @State private var lastImageScale: CGFloat = 1
    @State private var imageOffset: CGSize = .zero
    @State private var lastImageOffset: CGSize = .zero

    private let minimumScale: CGFloat = 1
    private let maximumScale: CGFloat = 5
    private let horizontalPadding: CGFloat = 0
    private let verticalPadding: CGFloat = 52

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .opacity(backgroundOpacity)
                .ignoresSafeArea()

            GeometryReader { proxy in
                let viewportSize = proxy.size
                let imageSize = fittedImageSize(in: viewportSize)

                Image(uiImage: storyboard.image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(imageScale * dismissalScale)
                    .offset(imageOffset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, verticalPadding)
                    .contentShape(Rectangle())
                    .gesture(imageGesture(imageSize: imageSize, viewportSize: viewportSize))
                    .onTapGesture(count: 2) {
                        withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) {
                            if imageScale > minimumScale {
                                resetZoom()
                            } else {
                                imageScale = 2.35
                                lastImageScale = imageScale
                            }

                            imageOffset = boundedOffset(
                                imageOffset,
                                imageSize: imageSize,
                                viewportSize: viewportSize
                            )
                            lastImageOffset = imageOffset
                        }
                    }
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Color.white.opacity(0.18), in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(closeButtonOpacity)
            .padding(.top, 18)
            .padding(.trailing, 18)
        }
        .background(Color.clear)
    }

    private func imageGesture(imageSize: CGSize, viewportSize: CGSize) -> some Gesture {
        SimultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    imageScale = rubberBandScale(lastImageScale * value)
                    imageOffset = boundedOffset(
                        imageOffset,
                        imageSize: imageSize,
                        viewportSize: viewportSize,
                        allowsResistance: true
                    )
                }
                .onEnded { _ in
                    withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.84)) {
                        imageScale = clampedScale(imageScale)
                        imageOffset = boundedOffset(
                            imageOffset,
                            imageSize: imageSize,
                            viewportSize: viewportSize
                        )

                        if imageScale <= minimumScale {
                            imageOffset = .zero
                        }

                        lastImageScale = imageScale
                        lastImageOffset = imageOffset
                    }
                },
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if imageScale <= minimumScale {
                        imageOffset = CGSize(
                            width: value.translation.width * 0.16,
                            height: max(value.translation.height, 0)
                        )
                        return
                    }

                    let proposedOffset = CGSize(
                        width: lastImageOffset.width + value.translation.width,
                        height: lastImageOffset.height + value.translation.height
                    )

                    imageOffset = boundedOffset(
                        proposedOffset,
                        imageSize: imageSize,
                        viewportSize: viewportSize,
                        allowsResistance: true
                    )
                }
                .onEnded { value in
                    if imageScale <= minimumScale {
                        closeOrResetAfterSwipe(value)
                        return
                    }

                    let projectedOffset = CGSize(
                        width: imageOffset.width + (value.predictedEndTranslation.width - value.translation.width) * 0.28,
                        height: imageOffset.height + (value.predictedEndTranslation.height - value.translation.height) * 0.28
                    )

                    withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.86)) {
                        imageOffset = boundedOffset(
                            projectedOffset,
                            imageSize: imageSize,
                            viewportSize: viewportSize
                        )
                        lastImageOffset = imageOffset
                    }
                }
        )
    }

    private func clampedScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, minimumScale), maximumScale)
    }

    private func rubberBandScale(_ scale: CGFloat) -> CGFloat {
        if scale < minimumScale {
            return minimumScale - ((minimumScale - scale) * 0.42)
        }

        if scale > maximumScale {
            return maximumScale + ((scale - maximumScale) * 0.18)
        }

        return scale
    }

    private func fittedImageSize(in viewportSize: CGSize) -> CGSize {
        let availableSize = CGSize(
            width: max(viewportSize.width - (horizontalPadding * 2), 1),
            height: max(viewportSize.height - (verticalPadding * 2), 1)
        )
        let sourceSize = storyboard.image.size
        let sourceAspectRatio = sourceSize.width / max(sourceSize.height, 1)
        let availableAspectRatio = availableSize.width / max(availableSize.height, 1)

        if sourceAspectRatio > availableAspectRatio {
            let height = availableSize.width / sourceAspectRatio
            return CGSize(width: availableSize.width, height: height)
        } else {
            let width = availableSize.height * sourceAspectRatio
            return CGSize(width: width, height: availableSize.height)
        }
    }

    private func boundedOffset(
        _ offset: CGSize,
        imageSize: CGSize,
        viewportSize: CGSize,
        allowsResistance: Bool = false
    ) -> CGSize {
        let bounds = offsetBounds(imageSize: imageSize, viewportSize: viewportSize)

        return CGSize(
            width: boundedValue(offset.width, limit: bounds.width, allowsResistance: allowsResistance),
            height: boundedValue(offset.height, limit: bounds.height, allowsResistance: allowsResistance)
        )
    }

    private func offsetBounds(imageSize: CGSize, viewportSize: CGSize) -> CGSize {
        let visibleSize = CGSize(
            width: max(viewportSize.width - (horizontalPadding * 2), 1),
            height: max(viewportSize.height - (verticalPadding * 2), 1)
        )

        return CGSize(
            width: max(((imageSize.width * imageScale) - visibleSize.width) / 2, 0),
            height: max(((imageSize.height * imageScale) - visibleSize.height) / 2, 0)
        )
    }

    private func boundedValue(_ value: CGFloat, limit: CGFloat, allowsResistance: Bool) -> CGFloat {
        guard limit > 0 else {
            return allowsResistance ? value * 0.18 : 0
        }

        guard abs(value) > limit else {
            return value
        }

        let overshoot = abs(value) - limit
        let resistedOvershoot = allowsResistance ? rubberBandDistance(overshoot) : 0
        return (limit + resistedOvershoot) * (value < 0 ? -1 : 1)
    }

    private func rubberBandDistance(_ distance: CGFloat) -> CGFloat {
        (1 - (1 / ((distance * 0.008) + 1))) * 120
    }

    private var backgroundOpacity: Double {
        guard imageScale <= minimumScale else {
            return 1
        }

        return 1 - (Double(dismissProgress) * 0.92)
    }

    private var dismissProgress: CGFloat {
        min(max(imageOffset.height / 260, 0), 1)
    }

    private var dismissalScale: CGFloat {
        guard imageScale <= minimumScale else {
            return 1
        }

        return 1 - (dismissProgress * 0.12)
    }

    private var closeButtonOpacity: Double {
        guard imageScale <= minimumScale else {
            return 1
        }

        return max(1 - Double(dismissProgress * 1.7), 0)
    }

    private func closeOrResetAfterSwipe(_ value: DragGesture.Value) {
        let isDownwardSwipe = value.translation.height > 120
        let isMostlyVertical = value.translation.height > abs(value.translation.width)

        if isDownwardSwipe && isMostlyVertical {
            dismiss()
            return
        }

        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            imageOffset = .zero
            lastImageOffset = .zero
        }
    }

    private func resetOffsetIfNeeded() {
        guard imageScale <= minimumScale else {
            return
        }

        imageOffset = .zero
        lastImageOffset = .zero
    }

    private func resetZoom() {
        imageScale = minimumScale
        lastImageScale = minimumScale
        imageOffset = .zero
        lastImageOffset = .zero
    }
}
