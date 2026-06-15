//
//  MultitouchManager.swift
//  MSHNCNTRLBTR
//
//  Bridges the private MultitouchSupport framework so we can read raw
//  trackpad touch frames and recognize custom 3- and 4-finger swipes.
//  Supports both one-shot discrete gestures and continuous "scrub"
//  gestures that emit incremental steps based on finger displacement.
//

import Foundation
import CoreGraphics

private let multitouchPath =
    "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

struct MTPoint {
    var x: Float
    var y: Float
}

struct MTReadout {
    var position: MTPoint
    var velocity: MTPoint
}

struct MTFinger {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var foo3: Int32
    var foo4: Int32
    var normalized: MTReadout
    var size: Float
    var zero1: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var mm: MTReadout
    var zero2_0: Int32
    var zero2_1: Int32
    var unk2: Float
}

typealias MTDeviceRef = OpaquePointer
typealias MTContactCallback = @convention(c) (
    MTDeviceRef?,
    UnsafeMutableRawPointer?,
    Int32,
    Double,
    Int32
) -> Int32

nonisolated final class MultitouchManager {
    static let shared = MultitouchManager()

    nonisolated(unsafe) var onAction: ((GestureAction) -> Void)?

    private var libraryHandle: UnsafeMutableRawPointer?
    private var device: MTDeviceRef?
    private var isRunning = false

    // Thread-safe snapshot of the user's bindings; updated from main.
    private let bindingsLock = NSLock()
    nonisolated(unsafe) private var _bindings: [GestureKey: GestureAction] = [:]
    nonisolated(unsafe) private var _enabled: Bool = true

    // Active finger count, read by the scroll-suppression event tap.
    private let fingerCountLock = NSLock()
    nonisolated(unsafe) private var _activeFingerCount: Int = 0

    private var scrollEventTap: CFMachPort?
    private var scrollRunLoopSource: CFRunLoopSource?

    // Per-finger start positions while the user is mid-swipe.
    private var startPositions: [Int32: (x: Float, y: Float)] = [:]
    private var lockedCount: Int = 0

    // For discrete gestures: latched after one emission until fingers lift.
    private var discreteLatched = false

    // For continuous "scrub" gestures.
    private struct ContinuousMode {
        let fingerCount: Int
        let axis: GestureAxis
        var anchor: Float
        let positiveAction: GestureAction?
        let negativeAction: GestureAction?
    }
    private var continuousMode: ContinuousMode?

    // 8% of the trackpad before a gesture engages.
    private let activationThreshold: Float = 0.08
    // After activation, each ~4% of further movement emits one step.
    private let scrubStep: Float = 0.04

    private init() {}

    // MARK: - Public configuration

    func setBindings(_ bindings: [GestureKey: GestureAction], enabled: Bool) {
        bindingsLock.lock()
        _bindings = bindings
        _enabled = enabled
        bindingsLock.unlock()
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }

        if libraryHandle == nil {
            libraryHandle = dlopen(multitouchPath, RTLD_NOW)
        }
        guard let handle = libraryHandle else {
            let msg = dlerror().map { String(cString: $0) } ?? "unknown error"
            NSLog("[MSHN] dlopen failed: \(msg)")
            return
        }

        guard let createSym = dlsym(handle, "MTDeviceCreateDefault"),
              let registerSym = dlsym(handle, "MTRegisterContactFrameCallback"),
              let startSym = dlsym(handle, "MTDeviceStart") else {
            NSLog("[MSHN] Could not resolve MultitouchSupport symbols.")
            return
        }

        typealias CreateFn = @convention(c) () -> MTDeviceRef?
        typealias RegisterFn = @convention(c) (MTDeviceRef?, MTContactCallback) -> Void
        typealias StartFn = @convention(c) (MTDeviceRef?, Int32) -> Void

        let create = unsafeBitCast(createSym, to: CreateFn.self)
        let register = unsafeBitCast(registerSym, to: RegisterFn.self)
        let startDevice = unsafeBitCast(startSym, to: StartFn.self)

        guard let dev = create() else {
            NSLog("[MSHN] MTDeviceCreateDefault returned nil.")
            return
        }
        device = dev
        register(dev, MultitouchManager.contactCallback)
        startDevice(dev, 0)
        isRunning = true

        installScrollSuppressionTap()
    }

    func stop() {
        guard isRunning, let handle = libraryHandle, let dev = device else { return }
        if let stopSym = dlsym(handle, "MTDeviceStop") {
            typealias StopFn = @convention(c) (MTDeviceRef?) -> Void
            let stopDevice = unsafeBitCast(stopSym, to: StopFn.self)
            stopDevice(dev)
        }
        isRunning = false
        uninstallScrollSuppressionTap()
    }

    // MARK: - Scroll suppression

    private func installScrollSuppressionTap() {
        guard scrollEventTap == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.scrollSuppressionCallback,
            userInfo: nil
        ) else {
            NSLog("[MSHN] Could not create scroll suppression event tap (Accessibility required).")
            return
        }
        scrollEventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        scrollRunLoopSource = source
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func uninstallScrollSuppressionTap() {
        if let tap = scrollEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = scrollRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        scrollEventTap = nil
        scrollRunLoopSource = nil
    }

    private static let scrollSuppressionCallback: CGEventTapCallBack = { _, type, event, _ in
        // Re-enable the tap if macOS disabled it (timeout / user input).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = MultitouchManager.shared.scrollEventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        if MultitouchManager.shared.shouldSuppressScroll() {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func shouldSuppressScroll() -> Bool {
        fingerCountLock.lock()
        defer { fingerCountLock.unlock() }
        return _activeFingerCount >= 3
    }

    private func setActiveFingerCount(_ count: Int) {
        fingerCountLock.lock()
        _activeFingerCount = count
        fingerCountLock.unlock()
    }

    // MARK: - Frame processing

    fileprivate static let contactCallback: MTContactCallback = { _, rawFingers, count, _, _ in
        let typed = rawFingers?.assumingMemoryBound(to: MTFinger.self)
        MultitouchManager.shared.handleFrame(fingers: typed, count: Int(count))
        return 0
    }

    fileprivate func handleFrame(fingers: UnsafeMutablePointer<MTFinger>?, count: Int) {
        setActiveFingerCount(count)

        if count == 0 {
            resetState()
            return
        }

        if count != 3 && count != 4 {
            resetState()
            lockedCount = count
            return
        }

        guard let fingers else { return }

        if lockedCount != count {
            startPositions.removeAll()
            for i in 0..<count {
                let f = fingers[i]
                startPositions[f.identifier] = (f.normalized.position.x, f.normalized.position.y)
            }
            lockedCount = count
            discreteLatched = false
            continuousMode = nil
            return
        }

        // Average displacement from the start of this finger configuration.
        var dx: Float = 0
        var dy: Float = 0
        var matched = 0
        for i in 0..<count {
            let f = fingers[i]
            if let start = startPositions[f.identifier] {
                dx += f.normalized.position.x - start.x
                dy += f.normalized.position.y - start.y
                matched += 1
            }
        }
        guard matched == count else { return }
        dx /= Float(count)
        dy /= Float(count)

        // If we're already scrubbing, keep emitting steps.
        if let cm = continuousMode {
            advanceContinuous(cm, dx: dx, dy: dy)
            return
        }

        if discreteLatched { return }

        // Not engaged yet — see if displacement has crossed the activation threshold.
        let absX = abs(dx)
        let absY = abs(dy)
        guard max(absX, absY) >= activationThreshold else { return }

        let axis: GestureAxis = absX > absY ? .horizontal : .vertical
        let dominant: SwipeDirection
        switch axis {
        case .horizontal: dominant = dx > 0 ? .right : .left
        case .vertical: dominant = dy > 0 ? .up : .down
        }

        guard let key = GestureKey.key(fingers: count, direction: dominant),
              let action = binding(for: key) else { return }

        if action.isContinuous {
            engageContinuous(fingerCount: count, axis: axis, dx: dx, dy: dy)
        } else {
            discreteLatched = true
            emit(action)
        }
    }

    private func engageContinuous(fingerCount: Int, axis: GestureAxis, dx: Float, dy: Float) {
        let positiveDir: SwipeDirection
        let negativeDir: SwipeDirection
        switch axis {
        case .horizontal: positiveDir = .right; negativeDir = .left
        case .vertical: positiveDir = .up; negativeDir = .down
        }

        let posKey = GestureKey.key(fingers: fingerCount, direction: positiveDir)
        let negKey = GestureKey.key(fingers: fingerCount, direction: negativeDir)
        // Only include actions on the opposite end if they're also continuous.
        let posAction = posKey.flatMap { binding(for: $0) }.flatMap { $0.isContinuous ? $0 : nil }
        let negAction = negKey.flatMap { binding(for: $0) }.flatMap { $0.isContinuous ? $0 : nil }

        let currentValue: Float = axis == .horizontal ? dx : dy
        var mode = ContinuousMode(
            fingerCount: fingerCount,
            axis: axis,
            anchor: 0,
            positiveAction: posAction,
            negativeAction: negAction
        )

        // Fire one immediate step since we just crossed the activation threshold.
        if currentValue > 0, let action = posAction {
            emit(action)
            mode.anchor = currentValue
        } else if currentValue < 0, let action = negAction {
            emit(action)
            mode.anchor = currentValue
        }

        continuousMode = mode
    }

    private func advanceContinuous(_ mode: ContinuousMode, dx: Float, dy: Float) {
        var cm = mode
        let current = cm.axis == .horizontal ? dx : dy
        let diff = current - cm.anchor

        if diff >= scrubStep, let action = cm.positiveAction {
            let steps = Int(diff / scrubStep)
            emit(action, times: steps)
            cm.anchor += Float(steps) * scrubStep
        } else if diff <= -scrubStep {
            if let action = cm.negativeAction {
                let steps = Int(-diff / scrubStep)
                emit(action, times: steps)
                cm.anchor -= Float(steps) * scrubStep
            } else {
                // No reverse binding: let the anchor track the finger so the
                // user doesn't have to "earn back" the dead zone before the
                // next forward emission.
                cm.anchor = current
            }
        }

        continuousMode = cm
    }

    private func resetState() {
        startPositions.removeAll()
        lockedCount = 0
        discreteLatched = false
        continuousMode = nil
    }

    // MARK: - Helpers

    private func binding(for key: GestureKey) -> GestureAction? {
        bindingsLock.lock()
        defer { bindingsLock.unlock() }
        guard _enabled else { return nil }
        return _bindings[key]
    }

    private func emit(_ action: GestureAction, times: Int = 1) {
        guard times > 0 else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<times {
                self.onAction?(action)
            }
        }
    }
}
