import AppKit
import Foundation

enum GestureWindowManager {
    static func execute(_ action: GestureWindowAction) -> Bool {
        dbgLog("ENTRY window_action action=\(action.rawValue)")
        guard let screen = NSScreen.main else {
            dbgLog("BAIL window_action reason=no_main_screen")
            return false
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            dbgLog("EXTERNAL NSWorkspace.frontmostApplication return=nil")
            dbgLog("BAIL window_action reason=no_frontmost_app")
            return false
        }
        dbgLog("EXTERNAL NSWorkspace.frontmostApplication return=\(app.localizedName ?? "unknown") pid=\(app.processIdentifier)")

        let visible = screen.visibleFrame
        let screenHeight = screen.frame.height
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        dbgLog("EXTERNAL AXUIElementCreateApplication pid=\(app.processIdentifier) return=created")

        var windowReference: CFTypeRef?
        let focusedWindowStatus = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowReference)
        dbgLog("EXTERNAL AXUIElementCopyAttributeValue attribute=focusedWindow status=\(focusedWindowStatus)")
        guard focusedWindowStatus == .success,
              let window = windowReference
        else {
            dbgLog("BAIL window_action reason=no_focused_window status=\(focusedWindowStatus)")
            return false
        }

        let windowElement = window as! AXUIElement

        if action == .center {
            return center(windowElement, in: visible, screenHeight: screenHeight)
        }

        let target = targetFrame(for: action, in: visible)
        let didSetFrame = setFrame(windowElement, frame: target, screenHeight: screenHeight)
        let raiseStatus = AXUIElementPerformAction(windowElement, kAXRaiseAction as CFString)
        dbgLog("EXTERNAL AXUIElementPerformAction action=raise status=\(raiseStatus)")
        let didActivate = app.activate()
        dbgLog("EXTERNAL NSRunningApplication.activate pid=\(app.processIdentifier) return=\(didActivate)")
        dbgLog("DONE window_action action=\(action.rawValue) didSetFrame=\(didSetFrame) didActivate=\(didActivate)")
        return didSetFrame
    }

    private static func center(_ window: AXUIElement, in visible: CGRect, screenHeight: CGFloat) -> Bool {
        var sizeRef: CFTypeRef?
        let sizeStatus = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
        dbgLog("EXTERNAL AXUIElementCopyAttributeValue attribute=size status=\(sizeStatus)")
        guard sizeStatus == .success,
              let sizeRef
        else {
            dbgLog("BAIL window_action_center reason=size_unavailable status=\(sizeStatus)")
            return false
        }

          let sizeValue = sizeRef as! AXValue

        var size = CGSize.zero
        AXValueGetValue(sizeValue, .cgSize, &size)

        let target = CGRect(
            x: visible.origin.x + (visible.width - size.width) / 2,
            y: visible.origin.y + (visible.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        return setFrame(window, frame: target, screenHeight: screenHeight)
    }

    private static func setFrame(_ window: AXUIElement, frame: CGRect, screenHeight: CGFloat) -> Bool {
        var axPosition = CGPoint(x: frame.origin.x, y: screenHeight - frame.origin.y - frame.height)
        var axSize = CGSize(width: frame.width, height: frame.height)
        dbgLog(String(format: "ENTRY window_set_frame x=%.1fpt y=%.1fpt w=%.1fpt h=%.1fpt", frame.origin.x, frame.origin.y, frame.width, frame.height))

        var didSetAnyValue = false

        if let positionValue = AXValueCreate(.cgPoint, &axPosition) {
            let positionStatus = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
            dbgLog("EXTERNAL AXUIElementSetAttributeValue attribute=position status=\(positionStatus)")
            didSetAnyValue = positionStatus == .success || didSetAnyValue
        }

        if let sizeValue = AXValueCreate(.cgSize, &axSize) {
            let sizeStatus = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            dbgLog("EXTERNAL AXUIElementSetAttributeValue attribute=size status=\(sizeStatus)")
            didSetAnyValue = sizeStatus == .success || didSetAnyValue
        }

        dbgLog("DONE window_set_frame didSetAnyValue=\(didSetAnyValue)")
        return didSetAnyValue
    }

    private static func targetFrame(for action: GestureWindowAction, in visible: CGRect) -> CGRect {
        let x = visible.origin.x
        let y = visible.origin.y
        let width = visible.width
        let height = visible.height
        let halfWidth = width / 2
        let halfHeight = height / 2

        switch action {
        case .leftHalf:
            return CGRect(x: x, y: y, width: halfWidth, height: height)
        case .rightHalf:
            return CGRect(x: x + halfWidth, y: y, width: halfWidth, height: height)
        case .topHalf:
            return CGRect(x: x, y: y + halfHeight, width: width, height: halfHeight)
        case .bottomHalf:
            return CGRect(x: x, y: y, width: width, height: halfHeight)
        case .topLeftQuarter:
            return CGRect(x: x, y: y + halfHeight, width: halfWidth, height: halfHeight)
        case .topRightQuarter:
            return CGRect(x: x + halfWidth, y: y + halfHeight, width: halfWidth, height: halfHeight)
        case .bottomLeftQuarter:
            return CGRect(x: x, y: y, width: halfWidth, height: halfHeight)
        case .bottomRightQuarter:
            return CGRect(x: x + halfWidth, y: y, width: halfWidth, height: halfHeight)
        case .center:
            return .zero
        case .maximize:
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }
}
