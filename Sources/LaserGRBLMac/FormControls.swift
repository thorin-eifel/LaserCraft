import SwiftUI

/// One spacing system for all dialogs: 8 pt between related controls, 12 pt between groups, 20 pt around a dialog.
enum Metrics {
    static let related: CGFloat = 8
    static let group: CGFloat = 12
    static let dialog: CGFloat = 20
    /// Width of a number field and of the unit text behind it, so that all fields of a column line up.
    static let field: CGFloat = 76
    static let unit: CGFloat = 52
}

/// A number field that clamps its value.
struct NumberInput: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = -1_000_000...1_000_000
    var digits = 3
    var width: CGFloat = Metrics.field

    var body: some View {
        TextField("", value: Binding(get: { value }, set: { value = min(range.upperBound, max(range.lowerBound, $0)) }),
                  format: .number.grouping(.never).precision(.fractionLength(0...digits)))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: width)
    }
}

/// "Title ........ [field] unit": the title on the left, the field and its unit right-aligned in fixed columns,
/// all vertically centred, so rows with and without a unit still line up.
struct UnitRow: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    var range: ClosedRange<Double> = -1_000_000...1_000_000
    var unit = ""
    var digits = 3

    init(_ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double> = -1_000_000...1_000_000, unit: String = "", digits: Int = 3) {
        self.title = title; self._value = value; self.range = range; self.unit = unit; self.digits = digits
    }

    var body: some View {
        HStack(alignment: .center, spacing: Metrics.related) {
            Text(title)
            Spacer(minLength: Metrics.related)
            NumberInput(value: $value, range: range, digits: digits)
            Text(verbatim: unit).font(.caption).foregroundStyle(.secondary).frame(width: Metrics.unit, alignment: .leading)
        }
    }
}

/// A row with a title on the left and any control on the right, vertically centred.
struct ControlRow<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }

    var body: some View {
        HStack(alignment: .center, spacing: Metrics.related) {
            Text(title)
            Spacer(minLength: Metrics.related)
            content
        }
    }
}
