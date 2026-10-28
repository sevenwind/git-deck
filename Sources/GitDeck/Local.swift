import SwiftUI

/// Замена `@State`: в SDK без Xcode (только Command Line Tools) макрос @State не раскрывается,
/// поэтому оборачиваем структуру SwiftUI.State напрямую.
@propertyWrapper
struct Local<Value>: DynamicProperty {
    private var storage: SwiftUI.State<Value>
    init(wrappedValue: Value) { storage = SwiftUI.State<Value>(wrappedValue: wrappedValue) }
    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }
    var projectedValue: Binding<Value> { storage.projectedValue }
}
