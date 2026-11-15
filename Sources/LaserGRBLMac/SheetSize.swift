import SwiftUI
import AppKit

/// Big dialogs (picture import, SVG, text, tracing) open as large as the window they belong to, so the preview gets all the
/// room there is; they can still be resized by the content's minimum only.
enum SheetSize {
    /// Width and height that nearly fill the main window (or the screen when there is no window yet).
    static var full: CGSize {
        let area = (NSApp.keyWindow ?? NSApp.mainWindow)?.frame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        return CGSize(width: max(820, area.width - 40), height: max(640, area.height - 40))
    }
}

extension View {
    /// Fills the available space by default (see `SheetSize.full`).
    func fullSheetFrame() -> some View {
        let s = SheetSize.full
        return frame(minWidth: 820, idealWidth: s.width, maxWidth: .infinity, minHeight: 640, idealHeight: s.height, maxHeight: .infinity)
    }
}
