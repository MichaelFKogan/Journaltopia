import SwiftUI
import UIKit

private let homeSampleImageNames = [
    "IMG_9080",
    "IMG_9144",
    "IMG_2390",
    "IMG_2382 2",
    "IMG_9131",
    "IMG_9113",
    "IMG_9127",
    "IMG_9126",
    "IMG_9114",
    "IMG_9102",
    "IMG_2385 2",
    "IMG_9140",
    "IMG_2214"
]

private func homeSampleImages(startIndex: Int, count: Int) -> [String] {
    guard !homeSampleImageNames.isEmpty else {
        return []
    }

    return (0..<count).map { offset in
        homeSampleImageNames[(startIndex + offset) % homeSampleImageNames.count]
    }
}

struct HomeView: View {
    @Binding var selectedPage: StoryPage
    @State private var selectedChapterPostOption: ChapterPostDisplayOption = .cards

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.homePageBackground
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    heroCard
                    storyboardsSection
                    chapterPostOptionsSection
                    socialFeedSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 92)
            }

            BottomNavigationBar(selectedPage: $selectedPage)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Storytopia")
                    .font(.system(size: 28, weight: .bold, design: .serif))
                    .foregroundStyle(Color.storyInk)

                Text("Your life, told in storyboards.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.homeMutedText)
            }

            Spacer()

            HStack(spacing: 10) {
                HeaderIconButton(systemName: "bell")
                HeaderIconButton(systemName: "person.fill")
            }
            .padding(.top, 5)
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create your\nfirst story")
                .font(.system(size: 26, weight: .bold, design: .serif))
                .lineSpacing(2)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            Text("Write about your day \nand turn it into a story.")
                .font(.system(size: 14, weight: .medium))
                .lineSpacing(2)
                .foregroundStyle(.white.opacity(0.92))

            Button {
                selectedPage = .create
            } label: {
                Label("New Story", systemImage: "plus")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.homeAccent)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
        .background {
            Image("homepage_banner")
                .resizable()
                .scaledToFill()
                .overlay(
                    LinearGradient(
                        colors: [.black.opacity(0.66), .black.opacity(0.22), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.homeBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.1), radius: 14, y: 6)
    }

    private var socialFeedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Recent moments", action: "View all")

            LazyVStack(spacing: 14) {
                ForEach(homeFeedPosts) { post in
                    HomeSocialFeedCard(
                        entry: post.entry,
                        accentColor: Color.homeAccent,
                        username: post.username,
                        dateText: post.dateText,
                        presentation: post.presentation
                    )
                }
            }
        }
    }

    private var homeFeedPosts: [HomeFeedPost] {
        [
            HomeFeedPost(
                entry: PrototypeEntry(
                    weekday: "WED",
                    day: "17",
                    title: "Chapter update",
                    body: "Added a new page to Summer in the City. The whole chapter is here as a little book.",
                    time: "4:38 PM",
                    location: "Brooklyn, NY",
                    imageNames: homeSampleImages(startIndex: 0, count: 8)
                ),
                username: "mikekogan",
                dateText: "Wed, Jun 17",
                presentation: .pageCurlBook(startIndex: 5)
            ),
            HomeFeedPost(
                entry: PrototypeEntry(
                    weekday: "WED",
                    day: "17",
                    title: "Fan stack chapter",
                    body: "A chapter preview with one story card centered and the rest fanned into stacks on both sides.",
                    time: "3:58 PM",
                    location: "Brooklyn, NY",
                    imageNames: homeSampleImages(startIndex: 2, count: 8)
                ),
                username: "mikekogan",
                dateText: "Wed, Jun 17",
                presentation: .fanCardStack(startIndex: 1)
            ),
            HomeFeedPost(
                entry: PrototypeEntry(
                    weekday: "WED",
                    day: "17",
                    title: "Collection stack",
                    body: "Added a new image to City fragments. Swipe through the collection as a little stack of cards.",
                    time: "3:22 PM",
                    location: "Brooklyn, NY",
                    imageNames: homeSampleImages(startIndex: 8, count: 5)
                ),
                username: "mikekogan",
                dateText: "Wed, Jun 17",
                presentation: .swipeCardStack(startIndex: 2)
            ),
            HomeFeedPost(
                entry: PrototypeEntry(
                    weekday: "TUE",
                    day: "16",
                    title: "A slow morning in Williamsburg",
                    body: "Coffee, a window seat, and nowhere I needed to be for an hour.",
                    time: "9:12 AM",
                    location: "Brooklyn, NY",
                    imageNames: homeSampleImages(startIndex: 4, count: 5)
                ),
                username: "mikekogan",
                dateText: "Tue, Jun 16",
                presentation: .singleImage
            ),
            HomeFeedPost(
                entry: PrototypeEntry(
                    weekday: "SUN",
                    day: "14",
                    title: "Sunday dinner",
                    body: "We stayed at the table long after dessert and retold the same family stories.",
                    time: "8:04 PM",
                    location: "Home",
                    imageNames: homeSampleImages(startIndex: 9, count: 4)
                ),
                username: "storytopia",
                dateText: "Sun, Jun 14",
                presentation: .singleImage
            )
        ]
    }

    private var storyboardsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Your storyboards", action: "View all")

            VStack(spacing: 3) {
                Text("You haven’t created any storyboards yet.")
                Text("Start by writing your first entry.")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.homeMutedText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.homeBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
        }
    }

    private var chapterPostOptionsSection: some View {
        ChapterPostOptionsSection(selectedOption: $selectedChapterPostOption)
    }
}

private enum ChapterPostDisplayOption: String, CaseIterable, Identifiable {
    case cards = "Cards"
    case book = "Book"
    case swipe = "Swipe"
    case shelf = "Shelf"
    case snap = "Snap"
    case fan = "Fan"

    var id: String { rawValue }
}

private enum ChapterPostDemoLayout {
    static let fullPageHeight: CGFloat = 510
    static let cardImageWidth: CGFloat = 242
    static let cardImageHeight: CGFloat = 363
    static let cardsDemoHeight: CGFloat = 412
    static let feedBookHeight: CGFloat = fullPageHeight
    static let feedStackHeight: CGFloat = 388
    static let collectionCarouselHeight: CGFloat = 430
    static let fanShelfHeight: CGFloat = 430
}

private struct HomeFeedPost: Identifiable {
    let id = UUID()
    let entry: PrototypeEntry
    let username: String
    let dateText: String
    let presentation: HomeFeedPresentation
}

private enum HomeFeedPresentation {
    case singleImage
    case pageCurlBook(startIndex: Int)
    case swipeCardStack(startIndex: Int)
    case fanCardStack(startIndex: Int)

    var initialPageIndex: Int {
        switch self {
        case .singleImage:
            return 0
        case .pageCurlBook(let startIndex):
            return startIndex
        case .swipeCardStack(let startIndex):
            return startIndex
        case .fanCardStack(let startIndex):
            return startIndex
        }
    }
}

private struct ChapterPostOptionsSection: View {
    @Binding var selectedOption: ChapterPostDisplayOption
    @State private var selectedPageIndex = 0

    private let chapterPageImageNames = homeSampleImages(startIndex: 0, count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Chapter post options")
                .font(.system(size: 18, weight: .bold, design: .serif))
                .foregroundStyle(Color.storyInk)
                .padding(.horizontal, 2)

            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ChapterPostDisplayOption.allCases) { option in
                            Button {
                                selectedOption = option
                            } label: {
                                Text(option.rawValue)
                                    .font(.system(size: 12, weight: .heavy))
                                    .foregroundStyle(selectedOption == option ? .white : Color.storyInk.opacity(0.76))
                                    .padding(.horizontal, 12)
                                    .frame(height: 30)
                                    .background(
                                        Capsule()
                                            .fill(selectedOption == option ? Color.homeAccent : Color.homeCardGray)
                                    )
                                    .overlay(
                                        Capsule()
                                            .stroke(selectedOption == option ? Color.homeAccent : Color.homeBorder, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 1)
                }

                Group {
                    switch selectedOption {
                    case .cards:
                        ChapterCardsDemo(imageNames: chapterPageImageNames)
                    case .book:
                        ChapterBookDemo(
                            imageNames: chapterPageImageNames,
                            selectedPageIndex: $selectedPageIndex
                        )
                    case .swipe:
                        ChapterScrollPageDemo(
                            imageNames: chapterPageImageNames,
                            selectedPageIndex: $selectedPageIndex
                        )
                    case .shelf:
                        ChapterCollectionCarouselDemo(
                            imageNames: chapterPageImageNames,
                            selectedPageIndex: $selectedPageIndex,
                            style: .groupPagingCentered
                        )
                    case .snap:
                        ChapterCollectionCarouselDemo(
                            imageNames: chapterPageImageNames,
                            selectedPageIndex: $selectedPageIndex,
                            style: .continuousLeading
                        )
                    case .fan:
                        ChapterFanShelfDemo(
                            imageNames: chapterPageImageNames,
                            selectedPageIndex: $selectedPageIndex
                        )
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: selectedOption)
            }
            .padding(12)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.homeBorder.opacity(0.88), lineWidth: 1)
            )
            .shadow(color: Color.storyInk.opacity(0.07), radius: 12, y: 5)
        }
    }
}

private struct ChapterScrollPageDemo: View {
    let imageNames: [String]
    @Binding var selectedPageIndex: Int

    var body: some View {
        VStack(spacing: 10) {
            ChapterPageSwipeView(imageNames: imageNames, currentIndex: $selectedPageIndex)
                .frame(height: ChapterPostDemoLayout.fullPageHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.homeBorder.opacity(0.78), lineWidth: 1)
                )

            HStack {
                Text("UIPageViewController scroll")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.homeMutedText)

                Spacer()

                ChapterPageCounter(currentIndex: selectedPageIndex, totalCount: imageNames.count)
            }
        }
    }
}

private enum ChapterCollectionCarouselStyle {
    case groupPagingCentered
    case continuousLeading

    var label: String {
        switch self {
        case .groupPagingCentered:
            return "UICollectionView centered group paging"
        case .continuousLeading:
            return "UICollectionView leading snap shelf"
        }
    }
}

private struct ChapterCollectionCarouselDemo: View {
    let imageNames: [String]
    @Binding var selectedPageIndex: Int
    let style: ChapterCollectionCarouselStyle

    var body: some View {
        VStack(spacing: 10) {
            ChapterCollectionCarouselView(
                imageNames: imageNames,
                currentIndex: $selectedPageIndex,
                style: style
            )
            .frame(height: ChapterPostDemoLayout.collectionCarouselHeight)
            .background(Color.homeCardGray)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.homeBorder.opacity(0.78), lineWidth: 1)
            )

            HStack {
                Text(style.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.homeMutedText)
                    .lineLimit(1)

                Spacer()

                ChapterPageCounter(currentIndex: selectedPageIndex, totalCount: imageNames.count)
            }
        }
    }
}

private struct ChapterFanShelfDemo: View {
    let imageNames: [String]
    @Binding var selectedPageIndex: Int
    @State private var fanDragOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                let cardWidth = min(geometry.size.width * 0.64, (geometry.size.height - 44) / 1.48)
                let cardHeight = cardWidth * 1.48

                ZStack {
                    Color.homeCardGray

                    ForEach(visibleIndices, id: \.self) { index in
                        let distance = index - selectedPageIndex

                        ChapterFanShelfCard(
                            imageName: imageNames[index]
                        )
                        .frame(width: cardWidth, height: cardHeight)
                        .scaleEffect(fanScale(for: distance, cardWidth: cardWidth))
                        .rotationEffect(.degrees(fanRotation(for: distance, cardWidth: cardWidth)))
                        .offset(
                            x: fanXOffset(for: distance, cardWidth: cardWidth),
                            y: fanYOffset(for: distance, cardWidth: cardWidth)
                        )
                        .shadow(color: Color.storyInk.opacity(distance == 0 ? 0.18 : 0.08), radius: distance == 0 ? 16 : 8, y: 8)
                        .zIndex(fanZIndex(for: distance, cardWidth: cardWidth))
                    }
                }
                .contentShape(Rectangle())
                .gesture(fanDragGesture)
                .animation(fanSpring, value: selectedPageIndex)
            }
            .frame(height: ChapterPostDemoLayout.fanShelfHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.homeBorder.opacity(0.78), lineWidth: 1)
            )

            HStack {
                Text("Custom stacked shelf")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.homeMutedText)

                Spacer()

                ChapterPageCounter(currentIndex: selectedPageIndex, totalCount: imageNames.count)
            }
        }
    }

    private var visibleIndices: [Int] {
        imageNames.indices.filter { index in
            index >= selectedPageIndex - 6 && index <= selectedPageIndex + 6
        }
    }

    private var fanDragGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                fanDragOffset = value.translation.width
            }
            .onEnded { value in
                let threshold: CGFloat = 80
                let projectedTranslation = value.predictedEndTranslation.width
                let shouldAdvance = value.translation.width < -threshold || projectedTranslation < -threshold * 1.25
                let shouldReverse = value.translation.width > threshold || projectedTranslation > threshold * 1.25

                withAnimation(fanSpring) {
                    if shouldAdvance {
                        selectedPageIndex = min(selectedPageIndex + 1, imageNames.count - 1)
                    } else if shouldReverse {
                        selectedPageIndex = max(selectedPageIndex - 1, 0)
                    }

                    fanDragOffset = 0
                }
            }
    }

    private var fanSpring: Animation {
        .interactiveSpring(response: 0.42, dampingFraction: 0.86, blendDuration: 0.12)
    }

    private func fanXOffset(for distance: Int, cardWidth: CGFloat) -> CGFloat {
        let position = fanPosition(for: distance, cardWidth: cardWidth)
        let absPosition = abs(position)

        guard absPosition > 0.001 else {
            return 0
        }

        let direction: CGFloat = position < 0 ? -1 : 1
        let stackOffset = cardWidth * 0.58

        if absPosition <= 1 {
            return position * stackOffset
        }

        return direction * (stackOffset + (absPosition - 1) * 10)
    }

    private func fanYOffset(for distance: Int, cardWidth: CGFloat) -> CGFloat {
        let position = fanPosition(for: distance, cardWidth: cardWidth)

        return min(abs(position) * 5, 24)
    }

    private func fanScale(for distance: Int, cardWidth: CGFloat) -> CGFloat {
        let absPosition = abs(fanPosition(for: distance, cardWidth: cardWidth))
        let sideProgress = min(absPosition, 1)
        let depthProgress = max(absPosition - 1, 0)

        return max(0.74, 1 - sideProgress * 0.14 - depthProgress * 0.018)
    }

    private func fanRotation(for distance: Int, cardWidth: CGFloat) -> Double {
        let position = fanPosition(for: distance, cardWidth: cardWidth)
        return Double(max(min(position, 3), -3)) * 1.15
    }

    private func fanZIndex(for distance: Int, cardWidth: CGFloat) -> Double {
        let position = abs(fanPosition(for: distance, cardWidth: cardWidth))
        return 100 - Double(position)
    }

    private func fanPosition(for distance: Int, cardWidth: CGFloat) -> CGFloat {
        let dragStep = cardWidth * 0.64
        let clampedDrag = min(max(fanDragOffset, -dragStep), dragStep)
        return CGFloat(distance) + clampedDrag / dragStep
    }

}

private struct ChapterFanShelfCard: View {
    let imageName: String
    private let cornerRadius: CGFloat = 7

    var body: some View {
        Image(imageName)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .background(Color.white, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.92), lineWidth: 5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.homeBorder.opacity(0.55), lineWidth: 1)
            )
    }
}

private struct ChapterCardsDemo: View {
    let imageNames: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(Array(imageNames.enumerated()), id: \.offset) { index, imageName in
                    VStack(alignment: .leading, spacing: 8) {
                        ChapterPageImage(imageName: imageName, cornerRadius: 7)
                            .frame(
                                width: ChapterPostDemoLayout.cardImageWidth,
                                height: ChapterPostDemoLayout.cardImageHeight
                            )

                        HStack {
                            Text("Page \(index + 1)")
                                .font(.system(size: 12, weight: .heavy))
                                .foregroundStyle(Color.storyInk)

                            Spacer()

                            Text("\(index + 1)/\(imageNames.count)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color.homeMutedText)
                        }
                    }
                    .padding(9)
                    .frame(width: 260)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.homeBorder.opacity(0.86), lineWidth: 1)
                    )
                    .shadow(color: Color.storyInk.opacity(0.08), radius: 8, y: 4)
                }
            }
            .padding(.vertical, 2)
            .padding(.trailing, 34)
        }
        .frame(height: ChapterPostDemoLayout.cardsDemoHeight)
    }
}

private struct ChapterBookDemo: View {
    let imageNames: [String]
    @Binding var selectedPageIndex: Int

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Color.homeCardGray

                ChapterPageCurlView(imageNames: imageNames, currentIndex: $selectedPageIndex)
                    .frame(height: ChapterPostDemoLayout.fullPageHeight)
            }
            .frame(height: ChapterPostDemoLayout.fullPageHeight)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.homeBorder.opacity(0.78), lineWidth: 1)
            )

            HStack {
                Text("Drag the page edge to curl")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.homeMutedText)

                Spacer()

                ChapterPageCounter(currentIndex: selectedPageIndex, totalCount: imageNames.count)
            }
        }
    }
}

private struct ChapterPageCounter: View {
    let currentIndex: Int
    let totalCount: Int

    var body: some View {
        Text("\(currentIndex + 1)/\(totalCount)")
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Color.storyInk.opacity(0.72), in: Capsule())
            .accessibilityLabel("Page \(currentIndex + 1) of \(totalCount)")
    }
}

private struct ChapterPageImage: View {
    let imageName: String
    let cornerRadius: CGFloat

    var body: some View {
        Image(imageName)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .background(Color.homeCardGray)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.homeBorder.opacity(0.7), lineWidth: 1)
            )
    }
}

private struct ChapterPageSwipeView: UIViewControllerRepresentable {
    let imageNames: [String]
    @Binding var currentIndex: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pageViewController = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal
        )
        pageViewController.dataSource = context.coordinator
        pageViewController.delegate = context.coordinator
        pageViewController.view.backgroundColor = .clear

        if let initialViewController = context.coordinator.viewController(for: currentIndex) {
            pageViewController.setViewControllers(
                [initialViewController],
                direction: .forward,
                animated: false
            )
        }

        return pageViewController
    }

    func updateUIViewController(_ pageViewController: UIPageViewController, context: Context) {
        context.coordinator.parent = self

        guard context.coordinator.displayedIndex != currentIndex,
              let targetViewController = context.coordinator.viewController(for: currentIndex) else {
            return
        }

        let direction: UIPageViewController.NavigationDirection = currentIndex > context.coordinator.displayedIndex ? .forward : .reverse
        pageViewController.setViewControllers(
            [targetViewController],
            direction: direction,
            animated: true
        )
        context.coordinator.displayedIndex = currentIndex
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: ChapterPageSwipeView
        var displayedIndex: Int

        init(_ parent: ChapterPageSwipeView) {
            self.parent = parent
            self.displayedIndex = parent.currentIndex
        }

        func viewController(for index: Int) -> UIViewController? {
            guard parent.imageNames.indices.contains(index) else {
                return nil
            }

            let pageView = ChapterPageImage(imageName: parent.imageNames[index], cornerRadius: 0)
                .ignoresSafeArea()
            let hostingController = UIHostingController(rootView: pageView)
            hostingController.view.backgroundColor = .clear
            hostingController.view.tag = index
            return hostingController
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore currentViewController: UIViewController
        ) -> UIViewController? {
            viewController(for: currentViewController.view.tag - 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter currentViewController: UIViewController
        ) -> UIViewController? {
            viewController(for: currentViewController.view.tag + 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            guard completed,
                  let visibleViewController = pageViewController.viewControllers?.first else {
                return
            }

            displayedIndex = visibleViewController.view.tag
            parent.currentIndex = displayedIndex
        }
    }
}

private struct ChapterCollectionCarouselView: UIViewRepresentable {
    let imageNames: [String]
    @Binding var currentIndex: Int
    let style: ChapterCollectionCarouselStyle

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UICollectionView {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.decelerationRate = .fast
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: Coordinator.reuseIdentifier)
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.parent = self
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        collectionView.reloadData()

        let indexPath = IndexPath(item: currentIndex, section: 0)
        if imageNames.indices.contains(currentIndex) {
            collectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: false)
        }
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .fractionalHeight(1)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)

        let groupWidth: CGFloat = style == .groupPagingCentered ? 0.76 : 0.84
        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(groupWidth),
            heightDimension: .fractionalHeight(0.92)
        )
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])

        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = style == .groupPagingCentered ? 14 : 10
        section.contentInsets = NSDirectionalEdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18)
        section.orthogonalScrollingBehavior = style == .groupPagingCentered ? .groupPagingCentered : .continuousGroupLeadingBoundary
        section.visibleItemsInvalidationHandler = { visibleItems, offset, environment in
            let centerX = offset.x + environment.container.contentSize.width / 2

            for item in visibleItems {
                let distance = abs(item.frame.midX - centerX)
                let normalizedDistance = min(distance / environment.container.contentSize.width, 1)
                let scale = 1 - normalizedDistance * 0.12
                item.transform = CGAffineTransform(scaleX: scale, y: scale)
                item.alpha = 1 - normalizedDistance * 0.18
            }
        }

        return UICollectionViewCompositionalLayout(section: section)
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        static let reuseIdentifier = "ChapterCollectionCarouselCell"

        var parent: ChapterCollectionCarouselView

        init(_ parent: ChapterCollectionCarouselView) {
            self.parent = parent
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.imageNames.count
        }

        func collectionView(
            _ collectionView: UICollectionView,
            cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: Self.reuseIdentifier, for: indexPath)
            let imageName = parent.imageNames[indexPath.item]
            cell.backgroundColor = .clear
            cell.contentView.backgroundColor = .clear
            cell.isOpaque = false
            cell.contentConfiguration = UIHostingConfiguration {
                ChapterCarouselCard(imageName: imageName, pageNumber: indexPath.item + 1, totalCount: parent.imageNames.count)
            }
            .margins(.all, 0)
            return cell
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            updateCurrentIndex(in: scrollView)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                updateCurrentIndex(in: scrollView)
            }
        }

        private func updateCurrentIndex(in scrollView: UIScrollView) {
            guard let collectionView = scrollView as? UICollectionView,
                  let centeredIndexPath = collectionView.indexPathForItem(at: CGPoint(x: collectionView.bounds.midX + collectionView.contentOffset.x, y: collectionView.bounds.midY)) else {
                return
            }

            parent.currentIndex = centeredIndexPath.item
        }
    }
}

private struct ChapterCarouselCard: View {
    let imageName: String
    let pageNumber: Int
    let totalCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ChapterPageImage(imageName: imageName, cornerRadius: 7)

            HStack {
                Text("Page \(pageNumber)")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(Color.storyInk)

                Spacer()

                Text("\(pageNumber)/\(totalCount)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.homeMutedText)
            }
        }
        .padding(9)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.homeBorder.opacity(0.86), lineWidth: 1)
        )
        .shadow(color: Color.storyInk.opacity(0.1), radius: 12, y: 6)
    }
}

private struct ChapterPageCurlView: UIViewControllerRepresentable {
    let imageNames: [String]
    @Binding var currentIndex: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pageViewController = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal
        )
        pageViewController.dataSource = context.coordinator
        pageViewController.delegate = context.coordinator
        pageViewController.view.backgroundColor = .clear
        pageViewController.view.clipsToBounds = false
        pageViewController.view.subviews.forEach { $0.clipsToBounds = false }
        pageViewController.isDoubleSided = false

        if let initialViewController = context.coordinator.viewController(for: currentIndex) {
            pageViewController.setViewControllers(
                [initialViewController],
                direction: .forward,
                animated: false
            )
        }

        return pageViewController
    }

    func updateUIViewController(_ pageViewController: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        pageViewController.view.clipsToBounds = false
        pageViewController.view.subviews.forEach { $0.clipsToBounds = false }

        guard context.coordinator.displayedIndex != currentIndex,
              let targetViewController = context.coordinator.viewController(for: currentIndex) else {
            return
        }

        let direction: UIPageViewController.NavigationDirection = currentIndex > context.coordinator.displayedIndex ? .forward : .reverse
        pageViewController.setViewControllers(
            [targetViewController],
            direction: direction,
            animated: true
        )
        context.coordinator.displayedIndex = currentIndex
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: ChapterPageCurlView
        var displayedIndex: Int

        init(_ parent: ChapterPageCurlView) {
            self.parent = parent
            self.displayedIndex = parent.currentIndex
        }

        func viewController(for index: Int) -> UIViewController? {
            guard parent.imageNames.indices.contains(index) else {
                return nil
            }

            let pageView = ChapterPageImage(imageName: parent.imageNames[index], cornerRadius: 0)
                .ignoresSafeArea()
            let hostingController = UIHostingController(rootView: pageView)
            hostingController.view.backgroundColor = .clear
            hostingController.view.clipsToBounds = false
            hostingController.view.tag = index
            return hostingController
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore currentViewController: UIViewController
        ) -> UIViewController? {
            viewController(for: currentViewController.view.tag - 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter currentViewController: UIViewController
        ) -> UIViewController? {
            viewController(for: currentViewController.view.tag + 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            guard completed,
                  let visibleViewController = pageViewController.viewControllers?.first else {
                return
            }

            displayedIndex = visibleViewController.view.tag
            parent.currentIndex = displayedIndex
        }
    }
}

private struct HomeSocialFeedCard: View {
    let entry: PrototypeEntry
    let accentColor: Color
    let username: String
    let dateText: String
    let presentation: HomeFeedPresentation
    @State private var currentSingleImageIndex: Int
    @State private var currentBookPageIndex: Int
    @State private var currentStackPageIndex: Int
    @GestureState private var stackDragOffset: CGFloat = 0

    private var activeSingleImageName: String? {
        guard entry.imageNames.indices.contains(currentSingleImageIndex) else {
            return entry.imageNames.first
        }

        return entry.imageNames[currentSingleImageIndex]
    }

    init(
        entry: PrototypeEntry,
        accentColor: Color,
        username: String,
        dateText: String,
        presentation: HomeFeedPresentation = .singleImage
    ) {
        self.entry = entry
        self.accentColor = accentColor
        self.username = username
        self.dateText = dateText
        self.presentation = presentation
        let maximumPageIndex = max(entry.imageNames.count - 1, 0)
        let initialPageIndex = min(max(presentation.initialPageIndex, 0), maximumPageIndex)
        _currentSingleImageIndex = State(initialValue: initialPageIndex)
        _currentBookPageIndex = State(initialValue: initialPageIndex)
        _currentStackPageIndex = State(initialValue: initialPageIndex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            feedHeader
                .zIndex(0)
            feedImage
                .zIndex(imageLayerZIndex)
            feedCaption
                .zIndex(captionLayerZIndex)
        }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.homeBorder.opacity(0.82), lineWidth: 1)
        )
        .shadow(color: Color.storyInk.opacity(0.08), radius: 14, y: 6)
        .accessibilityElement(children: .combine)
    }

    private var feedHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [accentColor.opacity(0.9), Color.storyRose.opacity(0.86), Color.storyGold.opacity(0.84)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .fill(Color.white)
                    .frame(width: 32, height: 32)

                Circle()
                    .fill(Color.homeCardGray)
                    .frame(width: 28, height: 28)

                Image(systemName: "person.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.homeMutedText)
            }
            .frame(width: 38, height: 38)
            .accessibilityLabel("Profile photo placeholder")

            VStack(alignment: .leading, spacing: 2) {
                Text(username)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(Color.storyInk)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(dateText)
                    Text("•")
                    Text(entry.time)
                    if let location = entry.location {
                        Text("•")
                        Text(location)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.homeMutedText)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.storyInk.opacity(0.58))
                .frame(width: 28, height: 28)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var feedImage: some View {
        switch presentation {
        case .pageCurlBook:
            feedBookImage
        case .swipeCardStack:
            feedSwipeCardStackImage
        case .fanCardStack:
            feedFanCardStackImage
        case .singleImage:
            feedSingleImage
        }
    }

    @ViewBuilder
    private var feedSingleImage: some View {
        if let activeSingleImageName {
            Image(activeSingleImageName)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 345, alignment: .top)
                .clipped()
                .id(activeSingleImageName)
                .overlay(alignment: .topTrailing) {
                    if entry.imageNames.count > 1 {
                        Text("\(currentSingleImageIndex + 1)/\(entry.imageNames.count)")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .background(Color.black.opacity(0.48), in: Capsule())
                            .padding(10)
                    }
                }
                .contentShape(Rectangle())
                .gesture(singleImageSwipeGesture)
                .animation(.easeInOut(duration: 0.18), value: currentSingleImageIndex)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "quote.opening")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(accentColor.opacity(0.56))

                Text(entry.body)
                    .font(.system(size: 24, weight: .bold, design: .serif))
                    .lineSpacing(3)
                    .foregroundStyle(Color.storyInk)
                    .lineLimit(5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 282)
            .padding(22)
            .background(Color.homeCardGray)
        }
    }

    private var feedBookImage: some View {
        ZStack {
            Color.homeCardGray

            ChapterPageCurlView(imageNames: entry.imageNames, currentIndex: $currentBookPageIndex)
                .frame(maxWidth: .infinity)
                .frame(height: ChapterPostDemoLayout.feedBookHeight)
                .zIndex(0)

            Label("Chapter", systemImage: "book.closed.fill")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Color.storyInk.opacity(0.62), in: Capsule())
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .zIndex(1)

            ChapterPageCounter(
                    currentIndex: currentBookPageIndex,
                    totalCount: entry.imageNames.count
                )
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .zIndex(1)
        }
        .frame(height: ChapterPostDemoLayout.feedBookHeight)
    }

    private var feedSwipeCardStackImage: some View {
        GeometryReader { geometry in
            let cardWidth = min(geometry.size.width * 0.66, 238)
            let cardHeight = geometry.size.height - 46

            ZStack {
                Color.homeCardGray

                ForEach(entry.imageNames.indices.reversed(), id: \.self) { index in
                    let distance = index - currentStackPageIndex

                    if abs(distance) <= 2 {
                        HomeSwipeThroughCard(
                            imageName: entry.imageNames[index],
                            title: stackCardTitle(for: index),
                            subtitle: stackCardSubtitle(for: index),
                            likes: stackCardLikes(for: index),
                            accentColor: accentColor
                        )
                        .frame(width: cardWidth, height: cardHeight)
                        .scaleEffect(stackCardScale(for: distance))
                        .rotationEffect(.degrees(stackCardRotation(for: distance)))
                        .offset(x: stackCardOffset(for: distance), y: abs(distance) == 0 ? 0 : 6)
                        .shadow(color: Color.storyInk.opacity(abs(distance) == 0 ? 0.18 : 0.08), radius: abs(distance) == 0 ? 16 : 8, y: 8)
                        .zIndex(stackCardZIndex(for: distance))
                    }
                }

                ChapterPageCounter(
                    currentIndex: currentStackPageIndex,
                    totalCount: entry.imageNames.count
                )
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .contentShape(Rectangle())
            .gesture(stackSwipeGesture)
        }
        .frame(height: ChapterPostDemoLayout.feedStackHeight)
    }

    private var feedFanCardStackImage: some View {
        GeometryReader { geometry in
            let cardWidth = min(geometry.size.width * 0.62, (geometry.size.height - 38) / 1.48)
            let cardHeight = cardWidth * 1.48

            ZStack {
                Color.homeCardGray

                ForEach(fanFeedVisibleIndices, id: \.self) { index in
                    let distance = index - currentStackPageIndex
                    let position = fanFeedPosition(for: distance, cardWidth: cardWidth)

                    ChapterFanShelfCard(imageName: entry.imageNames[index])
                        .frame(width: cardWidth, height: cardHeight)
                        .scaleEffect(fanFeedScale(for: position))
                        .rotationEffect(.degrees(fanFeedRotation(for: position)))
                        .offset(
                            x: fanFeedXOffset(for: position, cardWidth: cardWidth),
                            y: fanFeedYOffset(for: position)
                        )
                        .shadow(
                            color: Color.storyInk.opacity(abs(position) < 0.5 ? 0.18 : 0.08),
                            radius: abs(position) < 0.5 ? 16 : 8,
                            y: 8
                        )
                        .zIndex(fanFeedZIndex(for: position))
                }

                ChapterPageCounter(
                    currentIndex: currentStackPageIndex,
                    totalCount: entry.imageNames.count
                )
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .zIndex(120)
            }
            .contentShape(Rectangle())
            .gesture(stackSwipeGesture)
        }
        .frame(height: ChapterPostDemoLayout.feedStackHeight)
    }

    private var feedCaption: some View {
        VStack(alignment: .leading, spacing: 7) {
            (
                Text(entry.title)
                    .fontWeight(.heavy)
                + Text(" \(entry.body)")
            )
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.storyInk.opacity(0.86))
            .lineSpacing(2)
            .lineLimit(3)

            if entry.imageNames.count > 1 {
                HStack(spacing: 5) {
                    ForEach(entry.imageNames.indices, id: \.self) { index in
                        Circle()
                            .fill(index == activeImageIndex ? accentColor : Color.homeBorder)
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 13)
    }

    private var activeImageIndex: Int {
        switch presentation {
        case .singleImage:
            return currentSingleImageIndex
        case .pageCurlBook:
            return currentBookPageIndex
        case .swipeCardStack, .fanCardStack:
            return currentStackPageIndex
        }
    }

    private var imageLayerZIndex: Double {
        switch presentation {
        case .singleImage:
            return 0
        case .pageCurlBook, .swipeCardStack, .fanCardStack:
            return 3
        }
    }

    private var captionLayerZIndex: Double {
        0
    }

    private var singleImageSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onEnded { value in
                guard entry.imageNames.count > 1 else {
                    return
                }

                let threshold: CGFloat = 44
                if value.translation.width < -threshold {
                    currentSingleImageIndex = min(currentSingleImageIndex + 1, entry.imageNames.count - 1)
                } else if value.translation.width > threshold {
                    currentSingleImageIndex = max(currentSingleImageIndex - 1, 0)
                }
            }
    }

    private var stackSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .updating($stackDragOffset) { value, state, _ in
                state = value.translation.width
            }
            .onEnded { value in
                let threshold: CGFloat = 44
                if value.translation.width < -threshold {
                    currentStackPageIndex = min(currentStackPageIndex + 1, entry.imageNames.count - 1)
                } else if value.translation.width > threshold {
                    currentStackPageIndex = max(currentStackPageIndex - 1, 0)
                }
            }
    }

    private func stackCardOffset(for distance: Int) -> CGFloat {
        CGFloat(distance) * 44 + stackDragOffset
    }

    private func stackCardScale(for distance: Int) -> CGFloat {
        max(0.86, 1 - CGFloat(abs(distance)) * 0.07)
    }

    private func stackCardRotation(for distance: Int) -> Double {
        Double(distance) * 2.5
    }

    private func stackCardZIndex(for distance: Int) -> Double {
        Double(10 - abs(distance))
    }

    private var fanFeedVisibleIndices: [Int] {
        entry.imageNames.indices.filter { index in
            index >= currentStackPageIndex - 5 && index <= currentStackPageIndex + 5
        }
    }

    private func fanFeedPosition(for distance: Int, cardWidth: CGFloat) -> CGFloat {
        let dragStep = cardWidth * 0.74
        let clampedDrag = min(max(stackDragOffset, -dragStep), dragStep)
        return CGFloat(distance) + clampedDrag / dragStep
    }

    private func fanFeedXOffset(for position: CGFloat, cardWidth: CGFloat) -> CGFloat {
        let absPosition = abs(position)

        guard absPosition > 0.001 else {
            return 0
        }

        let direction: CGFloat = position < 0 ? -1 : 1
        let firstStackOffset = cardWidth * 0.17

        if absPosition <= 1 {
            return position * firstStackOffset
        }

        return direction * (firstStackOffset + (absPosition - 1) * 12)
    }

    private func fanFeedYOffset(for position: CGFloat) -> CGFloat {
        min(abs(position) * 4, 20)
    }

    private func fanFeedScale(for position: CGFloat) -> CGFloat {
        let absPosition = abs(position)
        let depthProgress = max(absPosition - 1, 0)

        return max(0.84, 1 - min(absPosition, 1) * 0.04 - depthProgress * 0.012)
    }

    private func fanFeedRotation(for position: CGFloat) -> Double {
        Double(max(min(position, 3), -3)) * 0.85
    }

    private func fanFeedZIndex(for position: CGFloat) -> Double {
        100 - Double(abs(position))
    }

    private func stackCardTitle(for index: Int) -> String {
        switch index {
        case 0:
            return "corner light"
        case 1:
            return "coffee run"
        case 2:
            return "new page"
        case 3:
            return "after rain"
        default:
            return "city note"
        }
    }

    private func stackCardSubtitle(for index: Int) -> String {
        index == currentStackPageIndex ? "Just added" : "\(index + 1) days ago"
    }

    private func stackCardLikes(for index: Int) -> Int {
        [7, 4, 12, 3, 9][index % 5]
    }
}

private struct HomeSwipeThroughCard: View {
    let imageName: String
    let title: String
    let subtitle: String
    let likes: Int
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(imageName)
                .resizable()
                .scaledToFill()
                .frame(height: 174)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(title)
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(Color.storyInk)
                .lineLimit(2)
                .minimumScaleFactor(0.82)

            Spacer(minLength: 4)

            Text(subtitle)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.homeMutedText)

            HStack(spacing: 18) {
                Label("\(likes)", systemImage: "heart")
                Image(systemName: "bubble.right")
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color.storyInk)
        }
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.92), lineWidth: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.homeBorder.opacity(0.55), lineWidth: 1)
        )
    }
}
