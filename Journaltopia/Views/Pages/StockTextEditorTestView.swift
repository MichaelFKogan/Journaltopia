import SwiftUI

/// Side-by-side comparison page: Create/Write layout using Apple's stock SwiftUI text controls
/// (`TextField` + `TextEditor`) instead of `LinedTextEditor`.
struct StockTextEditorTestView: View {
    @State private var storyTitle = ""
    @State private var entryText = ""
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case title
        case body
    }

    var body: some View {
        GeometryReader { proxy in
            let scrollContentHeight = max(proxy.size.height, UIScreen.main.bounds.height) * 2
            let bodyMinHeight = NotebookMetrics.bodyAreaMinHeight(
                forPageHeight: scrollContentHeight,
                titleBodySpacing: NotebookMetrics.titleBodySpacing
            )

            ScrollView {
                ZStack(alignment: .topLeading) {
                    NotebookPaperBackground(
                        paperColor: .homePageBackground,
                        showsPaperWash: false,
                        showsRuledLines: true,
                        showsNotebookChrome: true,
                        firstRuledLineY: NotebookMetrics.firstNotebookRuleY
                    )
                    .frame(maxWidth: .infinity, minHeight: scrollContentHeight, maxHeight: .infinity)

                    VStack(alignment: .leading, spacing: 0) {
                        titleRow

                        bodyEditor(minHeight: bodyMinHeight)
                            .padding(.top, NotebookMetrics.titleBodySpacing)
                    }
                    .padding(.leading, NotebookMetrics.marginLeading)
                    .padding(.trailing, 18)
                    .padding(.top, NotebookMetrics.contentTopPadding)
                    .padding(.bottom, NotebookMetrics.contentBottomPadding)
                }
                .frame(maxWidth: .infinity, minHeight: scrollContentHeight, alignment: .topLeading)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(Color.homePageBackground)
            .notebookPageChrome()
            .contentShape(Rectangle())
            .onTapGesture {
                focusedField = nil
            }
        }
        .background(Color.homePageBackground)
        .navigationTitle("Stock Text Editor")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(Color.homePageBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Insert Sample Paragraph") {
                        insertSampleParagraph()
                    }
                    Button("Insert Long Sample") {
                        insertLongSample()
                    }
                    Button("Clear All", role: .destructive) {
                        storyTitle = ""
                        entryText = ""
                        focusedField = .body
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Stock editor test actions")
            }

            ToolbarItemGroup(placement: .keyboard) {
                Text(statusLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.homeMutedText)

                Spacer()

                Button("Done") {
                    focusedField = nil
                }
                .font(.system(size: 14, weight: .bold))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if focusedField == nil {
                comparisonHintBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: focusedField == nil)
        .preferredColorScheme(.light)
    }

    private var titleRow: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                Rectangle()
                    .fill(NotebookMetrics.ruleColor)
                    .frame(height: 1)
                    .padding(.leading, -NotebookMetrics.marginLeading)
                    .padding(.trailing, -18)
            }

            TextField(
                "",
                text: $storyTitle,
                prompt: Text("Add a title")
                    .foregroundColor(Color.storyGray.opacity(0.46))
            )
            .font(NotebookMetrics.titleFont(for: .default))
            .foregroundStyle(NotebookTextStyle.default.color)
            .focused($focusedField, equals: .title)
            .textFieldStyle(.plain)
            .submitLabel(.next)
            .padding(.leading, NotebookMetrics.textLeadingInset)
            .padding(.top, NotebookMetrics.titleLineTextTopInset)
            .onSubmit {
                focusedField = .body
            }
        }
        .frame(height: NotebookMetrics.ruleSpacing)
    }

    private func bodyEditor(minHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $entryText)
                .focused($focusedField, equals: .body)
                .font(NotebookMetrics.bodyPlaceholderFont(for: .default))
                .foregroundStyle(NotebookTextStyle.default.color)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
                .padding(.leading, NotebookMetrics.textLeadingInset - 5)
                .padding(.top, -8)

            if entryText.isEmpty {
                Text("Start writing...")
                    .font(NotebookMetrics.bodyPlaceholderFont(for: .default))
                    .foregroundStyle(Color.storyGray.opacity(0.46))
                    .padding(.leading, NotebookMetrics.textLeadingInset)
                    .padding(.top, NotebookMetrics.firstLineTextTopInset(for: .default))
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture {
            focusedField = .body
        }
    }

    private var comparisonHintBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stock Apple controls")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.storyInk)

            Text("SwiftUI TextField + TextEditor only — no LinedTextEditor, rich text, or custom keyboard chrome. Compare typing/caret behavior with Create and Write Entry.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.homeMutedText)
                .fixedSize(horizontal: false, vertical: true)

            Text(statusLabel)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.homeAccent)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.homePageBackground.opacity(0.96))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.storyBorder.opacity(0.45))
                .frame(height: 0.5)
        }
    }

    private var statusLabel: String {
        let characters = entryText.count
        let words = entryText
            .split { $0.isWhitespace || $0.isNewline }
            .count
        return "\(characters) chars · \(words) words"
    }

    private func insertSampleParagraph() {
        let sample = "The rain made the windows look like watercolor. I found a table near the plants and started sketching a character who keeps small maps in her coat pocket."
        appendSample(sample)
    }

    private func insertLongSample() {
        let paragraph = "Stock TextEditor stress line. Type freely and watch whether the caret stays where you put it when characters wrap, when you jump mid-word, and when the outer page scrolls."
        let sample = Array(repeating: paragraph, count: 12).joined(separator: "\n\n")
        appendSample(sample)
    }

    private func appendSample(_ sample: String) {
        let trimmed = entryText.trimmingCharacters(in: .whitespacesAndNewlines)
        entryText = trimmed.isEmpty ? sample : "\(trimmed)\n\n\(sample)"
        focusedField = .body
    }
}
