import SwiftUI

extension View {
    /// Use the current API on Sonoma and later, with the same new-value callback
    /// on Ventura. Neither branch invokes the action on initial appearance.
    @ViewBuilder
    func onRemarcChange<Value: Equatable>(
        of value: Value,
        perform action: @escaping (Value) -> Void
    ) -> some View {
        if #available(macOS 14, *) {
            onChange(of: value) { _, newValue in action(newValue) }
        } else {
            onChange(of: value, perform: action)
        }
    }
}
