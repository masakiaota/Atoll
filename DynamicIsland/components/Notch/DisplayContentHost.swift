import AppKit
import Combine

/// Owns only the currently needed hosting view. Keeping the factories lazy is
/// important: an inactive display must never construct ContentView at launch.
@MainActor
final class DisplayContentHost: NSView {
    var isPointerOnScreen: Bool { didSet { updateContent() } }
    var isNotchOpen: Bool { didSet { updateContent() } }
    var cancellables: Set<AnyCancellable> = []

    private let makeContent: () -> NSView
    private let makePlaceholder: () -> NSView
    private let releaseContent: () -> Void
    private var showingContent: Bool?

    init(
        isPointerOnScreen: Bool,
        isNotchOpen: Bool,
        makeContent: @escaping () -> NSView,
        makePlaceholder: @escaping () -> NSView,
        releaseContent: @escaping () -> Void
    ) {
        self.isPointerOnScreen = isPointerOnScreen
        self.isNotchOpen = isNotchOpen
        self.makeContent = makeContent
        self.makePlaceholder = makePlaceholder
        self.releaseContent = releaseContent
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        updateContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func updateContent() {
        let required = isPointerOnScreen || isNotchOpen
        guard showingContent != required else { return }
        let wasShowingContent = showingContent == true
        showingContent = required
        if wasShowingContent { releaseContent() }
        subviews.forEach { $0.removeFromSuperview() }

        let view = required ? makeContent() : makePlaceholder()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }
}
