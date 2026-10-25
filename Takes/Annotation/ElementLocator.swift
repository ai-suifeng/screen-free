import ApplicationServices
import AppKit

/// Finds the on-screen bounds of the UI element under a point, via the Accessibility API.
enum ElementLocator {
    private static let containerRoles: Set<String> = [
        "AXButton", "AXCell", "AXRow", "AXMenuItem", "AXMenuBarItem", "AXLink", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXMenuButton", "AXTab", "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
        "AXDisclosureTriangle", "AXSlider", "AXIncrementor", "AXColorWell", "AXSegmentedControl",
    ]
    private static let leafRoles: Set<String> = ["AXStaticText", "AXImage", "AXUnknown", "AXGroup"]

    /// Returns the element frame in CG global coordinates, or nil if nothing sensible was found.
    /// `maxArea` rejects huge containers such as whole web views.
    static func frame(at point: CGPoint, maxArea: CGFloat) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return nil }

        // Prefer the interactive control over the label or icon inside it.
        for _ in 0..<3 {
            let role = string(element, kAXRoleAttribute) ?? ""
            if containerRoles.contains(role) { break }
            guard leafRoles.contains(role), let parent = parent(of: element),
                  let parentRole = string(parent, kAXRoleAttribute), containerRoles.contains(parentRole)
                    || (frame(of: parent).map { $0.width * $0.height < 160 * 60 } ?? false) else { break }
            element = parent
        }

        guard let rect = frame(of: element), rect.width >= 6, rect.height >= 6,
              rect.width * rect.height <= maxArea, rect.contains(point) else { return nil }
        return rect
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let posValue, let sizeValue else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }
}
