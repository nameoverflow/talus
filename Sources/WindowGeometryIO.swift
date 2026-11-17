import Foundation
import ApplicationServices
import CoreGraphics

func axValue(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute, &result) == .success ? result : nil
}

func frame(_ element: AXUIElement) -> CGRect? {
    var batch: CFArray?
    let error = AXUIElementCopyMultipleAttributeValues(element, [kAXPositionAttribute, kAXSizeAttribute] as CFArray,
        AXCopyMultipleAttributeOptions(rawValue: 0), &batch)
    if error == .cannotComplete || error == .invalidUIElement { return nil }
    let values = batch as? [CFTypeRef]
    var p: CFTypeRef?, s: CFTypeRef?
    if let values, values.count == 2,
       CFGetTypeID(values[0]) == AXValueGetTypeID(), CFGetTypeID(values[1]) == AXValueGetTypeID() {
        p = values[0]; s = values[1]
    } else {
        p = axValue(element, kAXPositionAttribute as CFString)
        s = axValue(element, kAXSizeAttribute as CFString)
    }
    guard let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}

func matchesFrame(_ actual: CGRect, _ target: CGRect, parking: Bool = false) -> Bool {
    abs(actual.minX - target.minX) < (parking ? 3 : 1)
        && (parking || abs(actual.minY - target.minY) < 1)
        && abs(actual.width - target.width) < 1 && abs(actual.height - target.height) < 1
}

@discardableResult
func setPosition(_ element: AXUIElement, _ origin: CGPoint) -> AXError {
    var point = origin
    guard let value = AXValueCreate(.cgPoint, &point) else { return .failure }
    return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
}

struct FrameAccess {
    let read: () -> CGRect?
    let position: (CGPoint) -> AXError
    let size: (CGSize) -> AXError
    var settle: () -> Void = { Thread.sleep(forTimeInterval: 0.016) }
}

@discardableResult
func setFrame(_ element: AXUIElement, _ target: CGRect, current: CGRect? = nil, parking: Bool = false,
              access: FrameAccess? = nil) -> AXError {
    let io = access ?? FrameAccess(read: { frame(element) }, position: { setPosition(element, $0) }, size: { requested in
        var size = requested
        guard let value = AXValueCreate(.cgSize, &size) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    })
    let error: AXError
    if let current, abs(current.width - target.width) < 1, abs(current.height - target.height) < 1 {
        error = io.position(target.origin)
    } else {
        _ = io.size(target.size)
        let moved = io.position(target.origin)
        let resized = io.size(target.size)
        error = moved == .success ? resized : moved
    }
    guard error == .success else { return error }
    if let actual = io.read(), matchesFrame(actual, target, parking: parking) { return .success }
    // An AX provider may acknowledge before its next run-loop turn applies
    // position/size. Success must describe the real frame, not just the reply.
    io.settle()
    guard let actual = io.read(), matchesFrame(actual, target, parking: parking) else { return .cannotComplete }
    return .success
}
