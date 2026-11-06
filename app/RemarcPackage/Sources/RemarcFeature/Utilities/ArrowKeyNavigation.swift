import AppKit
import SwiftUI

extension View {
    @ViewBuilder
    func remarcArrowKeys(onMove: @escaping (Int) -> Void) -> some View {
        if #available(macOS 14, *) {
            self
                .onKeyPress(.downArrow) {
                    onMove(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    onMove(-1)
                    return .handled
                }
        } else {
            background(LegacyArrowKeyNavigation(onMove: onMove))
        }
    }
}

private struct LegacyArrowKeyNavigation: NSViewRepresentable {
    var onMove: (Int) -> Void

    func makeNSView(context: Context) -> ArrowKeyNavigationView {
        ArrowKeyNavigationView(onMove: onMove)
    }

    func updateNSView(_ view: ArrowKeyNavigationView, context: Context) {
        view.onMove = onMove
    }

    static func dismantleNSView(_ view: ArrowKeyNavigationView, coordinator: ()) {
        view.stopMonitoring()
    }
}

@MainActor
final class ArrowKeyNavigationView: NSView {
    var onMove: (Int) -> Void
    private var monitor: Any?

    init(onMove: @escaping (Int) -> Void) {
        self.onMove = onMove
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window,
                  event.window === window, window.isKeyWindow, window.isVisible,
                  !self.isHiddenOrHasHiddenAncestor,
                  let direction = Self.direction(for: event, firstResponder: window.firstResponder)
            else { return event }
            self.onMove(direction)
            return nil
        }
    }

    func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    static func direction(for event: NSEvent, firstResponder: NSResponder?) -> Int? {
        // Search fields and comment editors keep their native caret navigation.
        guard !(firstResponder is NSTextView), !(firstResponder is NSTextField),
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        else { return nil }
        switch event.keyCode {
        case 125: return 1
        case 126: return -1
        default: return nil
        }
    }
}
