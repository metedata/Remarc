import Foundation

public struct WebContext: Codable, Equatable, Sendable {
    public var componentName: String?
    public var filePath: String?
    public var reactComponents: String?
    public var elementName: String?
    public var elementPath: String?
    public var selectedText: String?
    public var cssClasses: String?
    public var selector: String?
    public var computedStyles: String?
    public var accessibility: String?
    public var nearbyText: String?
    public var nearbyElements: String?
    public var boundingBox: BoundingBox?
    public var pageUrl: String?
    /// Optional HyperFrames composition context (beat, active tweens, source-line ranges)
    /// for comments captured on HF compositions. Populated by the composition's
    /// `window.__remarcHFContext` bridge via the Chrome extension. Debug-only:
    /// `WebContext.filtered()` drops this field unless
    /// `SettingsManager.shared.webContextHyperframesEnabled` is true.
    public var hyperframesContext: String?

    public struct BoundingBox: Codable, Equatable, Sendable {
        public var x: Int?
        public var y: Int?
        public var width: Int?
        public var height: Int?
    }

    public init(
        componentName: String? = nil,
        filePath: String? = nil,
        reactComponents: String? = nil,
        elementName: String? = nil,
        elementPath: String? = nil,
        selectedText: String? = nil,
        cssClasses: String? = nil,
        selector: String? = nil,
        computedStyles: String? = nil,
        accessibility: String? = nil,
        nearbyText: String? = nil,
        nearbyElements: String? = nil,
        boundingBox: BoundingBox? = nil,
        pageUrl: String? = nil,
        hyperframesContext: String? = nil
    ) {
        self.componentName = componentName
        self.filePath = filePath
        self.reactComponents = reactComponents
        self.elementName = elementName
        self.elementPath = elementPath
        self.selectedText = selectedText
        self.cssClasses = cssClasses
        self.selector = selector
        self.computedStyles = computedStyles
        self.accessibility = accessibility
        self.nearbyText = nearbyText
        self.nearbyElements = nearbyElements
        self.boundingBox = boundingBox
        self.pageUrl = pageUrl
        self.hyperframesContext = hyperframesContext
    }

    // MARK: - Codable (with back-compat for legacy structured shape)

    private enum CodingKeys: String, CodingKey {
        case componentName, filePath, reactComponents, elementName, elementPath
        case selectedText, cssClasses, selector, computedStyles, accessibility
        case nearbyText, nearbyElements, boundingBox, pageUrl
        case hyperframesContext
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.componentName = try c.decodeIfPresent(String.self, forKey: .componentName)
        self.filePath = try c.decodeIfPresent(String.self, forKey: .filePath)
        self.reactComponents = try c.decodeIfPresent(String.self, forKey: .reactComponents)
        self.elementName = try c.decodeIfPresent(String.self, forKey: .elementName)
        self.elementPath = try c.decodeIfPresent(String.self, forKey: .elementPath)
        self.selectedText = try c.decodeIfPresent(String.self, forKey: .selectedText)
        self.cssClasses = try c.decodeIfPresent(String.self, forKey: .cssClasses)
        self.selector = try c.decodeIfPresent(String.self, forKey: .selector)
        self.boundingBox = try c.decodeIfPresent(BoundingBox.self, forKey: .boundingBox)
        self.pageUrl = try c.decodeIfPresent(String.self, forKey: .pageUrl)
        self.hyperframesContext = try c.decodeIfPresent(String.self, forKey: .hyperframesContext)

        self.computedStyles = WebContext.decodeFlatOrStructured(
            container: c, key: .computedStyles,
            flatten: { (dict: [String: String]) in
                dict.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
            }
        )
        self.accessibility = WebContext.decodeFlatOrStructured(
            container: c, key: .accessibility,
            flatten: { (info: LegacyAccessibility) in info.flatten() }
        )
        self.nearbyText = WebContext.decodeFlatOrStructured(
            container: c, key: .nearbyText,
            flatten: { (info: LegacyNearbyText) in info.flatten() }
        )
        self.nearbyElements = WebContext.decodeFlatOrStructured(
            container: c, key: .nearbyElements,
            flatten: { (els: [LegacyNearbyElement]) in
                els.map(\.formatted).joined(separator: " | ")
            }
        )
    }

    /// Try to decode `key` as a String first; if it's a legacy structured shape,
    /// decode that and flatten it. Missing or invalid → nil.
    private static func decodeFlatOrStructured<T: Decodable>(
        container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys,
        flatten: (T) -> String
    ) -> String? {
        if let s = try? container.decodeIfPresent(String.self, forKey: key) {
            return s.isEmpty ? nil : s
        }
        if let structured = try? container.decodeIfPresent(T.self, forKey: key) {
            let s = flatten(structured)
            return s.isEmpty ? nil : s
        }
        return nil
    }

    // Legacy shapes used only during decode for back-compat.

    private struct LegacyAccessibility: Decodable {
        var role: String?
        var ariaLabel: String?
        var ariaDescribedby: String?
        var ariaHidden: String?
        var tabIndex: Int?
        var focusable: Bool?
        func flatten() -> String {
            var parts: [String] = []
            if let r = role { parts.append("role=\(r)") }
            if let l = ariaLabel { parts.append("aria-label=\"\(l)\"") }
            if let d = ariaDescribedby { parts.append("aria-describedby=\"\(d)\"") }
            if let h = ariaHidden { parts.append("aria-hidden=\(h)") }
            if let t = tabIndex { parts.append("tabIndex=\(t)") }
            if let f = focusable { parts.append("focusable=\(f)") }
            return parts.joined(separator: ", ")
        }
    }

    private struct LegacyNearbyText: Decodable {
        var element: String?
        var before: String?
        var after: String?
        func flatten() -> String {
            var parts: [String] = []
            if let b = before { parts.append("before: \"\(b)\"") }
            if let a = after { parts.append("after: \"\(a)\"") }
            return parts.joined(separator: "; ")
        }
    }

    private struct LegacyNearbyElement: Decodable {
        var tag: String?
        var classes: String?
        var id: String?
        var textSnippet: String?
        var formatted: String {
            let t = tag ?? "?"
            let i = id.map { "#\($0)" } ?? ""
            let cls = classes.map { "." + $0.split(separator: " ").prefix(3).joined(separator: ".") } ?? ""
            let txt = textSnippet.map { " \"\($0)\"" } ?? ""
            return "<\(t)\(i)\(cls)>\(txt)"
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(componentName, forKey: .componentName)
        try c.encodeIfPresent(filePath, forKey: .filePath)
        try c.encodeIfPresent(reactComponents, forKey: .reactComponents)
        try c.encodeIfPresent(elementName, forKey: .elementName)
        try c.encodeIfPresent(elementPath, forKey: .elementPath)
        try c.encodeIfPresent(selectedText, forKey: .selectedText)
        try c.encodeIfPresent(cssClasses, forKey: .cssClasses)
        try c.encodeIfPresent(selector, forKey: .selector)
        try c.encodeIfPresent(computedStyles, forKey: .computedStyles)
        try c.encodeIfPresent(accessibility, forKey: .accessibility)
        try c.encodeIfPresent(nearbyText, forKey: .nearbyText)
        try c.encodeIfPresent(nearbyElements, forKey: .nearbyElements)
        try c.encodeIfPresent(boundingBox, forKey: .boundingBox)
        try c.encodeIfPresent(pageUrl, forKey: .pageUrl)
        try c.encodeIfPresent(hyperframesContext, forKey: .hyperframesContext)
    }

    // MARK: - Privacy filter

    /// Returns a copy with fields nulled per user's metadata toggle preferences.
    /// Returns `nil` if all fields are stripped (all toggles off → no web context saved).
    @MainActor
    public func filtered() -> WebContext? {
        let s = SettingsManager.shared
        var copy = self
        if !s.webContextReactEnabled {
            copy.componentName = nil; copy.filePath = nil
            copy.reactComponents = nil
        }
        if !s.webContextStylesEnabled { copy.computedStyles = nil }
        if !s.webContextAccessibilityEnabled { copy.accessibility = nil }
        if !s.webContextLayoutEnabled {
            copy.boundingBox = nil
            copy.nearbyElements = nil; copy.nearbyText = nil
        }
        if !s.webContextIdentityEnabled {
            copy.elementName = nil; copy.elementPath = nil
            copy.selectedText = nil; copy.cssClasses = nil
            copy.selector = nil; copy.pageUrl = nil
        }
        // Debug-only / experimental: drop HF context entirely unless explicitly enabled.
        if !s.webContextHyperframesEnabled {
            copy.hyperframesContext = nil
        }
        let hasContent = copy.componentName != nil || copy.filePath != nil
            || copy.reactComponents != nil
            || copy.computedStyles != nil || copy.accessibility != nil || copy.boundingBox != nil
            || copy.nearbyElements != nil || copy.nearbyText != nil
            || copy.elementName != nil || copy.elementPath != nil
            || copy.selectedText != nil || copy.cssClasses != nil
            || copy.selector != nil || copy.pageUrl != nil
            || copy.hyperframesContext != nil
        return hasContent ? copy : nil
    }

    /// Human-readable summary for display in comment cards.
    /// Example: "LoginForm · login-form.tsx:46" or "button [Play] · ..."
    public var displaySummary: String? {
        let parts = [WebContext.smartLabel(componentName: componentName, elementName: elementName), filePath].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// Smart identifier picker: matches Agentation's behavior of preferring the
    /// DOM-derived elementName (text-content based, like `button "Save"` or
    /// `link "Priority"`) as the primary label. Falls back to componentName
    /// only when there's no elementName. componentName is still shown
    /// separately in the popover for source navigation context.
    public static func smartLabel(componentName: String?, elementName: String?) -> String? {
        if let e = elementName, !e.isEmpty { return e }
        if let c = componentName, isMeaningfulComponentName(c) { return c }
        return nil
    }

    /// True if the name looks like a real React component (PascalCase, 3+ chars).
    /// Minified production names (xC, _4) and hooks (useState) return false.
    public static func isMeaningfulComponentName(_ name: String) -> Bool {
        guard name.count >= 3, let first = name.first else { return false }
        return first.isUppercase
    }

    public var hasSelectedText: Bool {
        selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}
