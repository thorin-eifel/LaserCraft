import SwiftUI
import AppKit

/// SF Symbols used by the app. The short names are what the code (and saved custom buttons) refer to.
enum Symbols {
    static let map: [String: String] = [
        "folder": "folder", "image": "photo", "save": "square.and.arrow.down", "sliders": "slider.horizontal.3",
        "play": "play.fill", "pause": "pause.fill", "stop": "stop.fill",
        "reset": "arrow.counterclockwise", "refresh": "arrow.clockwise",
        "plug": "cable.connector", "unplug": "bolt.slash",
        "home": "house", "unlock": "lock.open", "lock": "lock", "target": "scope", "fit": "square.dashed",
        "zoomin": "plus.magnifyingglass", "zoomout": "minus.magnifyingglass",
        "terminal": "terminal", "trash": "trash", "plus": "plus", "settings": "gearshape",
        "list": "list.bullet", "document": "doc.text",
        "up": "arrow.up", "down": "arrow.down", "left": "arrow.left", "right": "arrow.right",
        "upleft": "arrow.up.left", "upright": "arrow.up.right", "downleft": "arrow.down.left", "downright": "arrow.down.right",
        "check": "checkmark", "cross": "xmark", "awake": "cup.and.saucer.fill", "rotl": "rotate.left", "rotr": "rotate.right", "snow": "snowflake",
        "crop": "crop", "arrange": "rectangle.3.group", "undo": "arrow.uturn.backward", "redo": "arrow.uturn.forward", "copy": "doc.on.doc", "center": "plus.viewfinder",
        "layers": "square.3.layers.3d", "camera": "camera", "wifi": "wifi", "tools": "wrench.and.screwdriver", "chart": "chart.bar", "book": "books.vertical",
    ]

    static func name(for key: String) -> String { map[key] ?? key }
}

/// An SF Symbol at a fixed size; it follows tint, dark mode, the disabled state and the text weight.
struct UIcon: View {
    let name: String
    var size: CGFloat = 15
    var rotation: Double = 0

    var body: some View {
        Image(systemName: Symbols.name(for: name))
            .font(.system(size: size))
            .frame(width: size + 4, height: size + 4)
            .rotationEffect(.degrees(rotation))
            .accessibilityHidden(true)
    }
}

/// A title with a symbol; toolbars show the symbol, menus and accessibility use the title.
struct IconLabel: View {
    let title: LocalizedStringKey
    let icon: String
    var size: CGFloat = 15

    init(_ title: LocalizedStringKey, icon: String, size: CGFloat = 15) {
        self.title = title; self.icon = icon; self.size = size
    }

    var body: some View {
        Label { Text(title) } icon: { UIcon(name: icon, size: size) }
    }
}
