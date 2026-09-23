//
//  RunLoopLocalEventMonitor.swift
//  Ice
//

import Cocoa
import Combine

@MainActor
final class RunLoopLocalEventMonitor {
    private let runLoop = CFRunLoopGetMain()
    private let mode: RunLoop.Mode
    private let mask: NSEvent.EventTypeMask
    private let handler: @MainActor (NSEvent) -> Void
    private var observer: CFRunLoopObserver?
    private var isProcessing = false
    private var lastEvent: NSEvent?

    /// Creates an event monitor with the given event type mask and handler.
    ///
    /// - Parameters:
    ///   - mask: An event type mask specifying which events to monitor.
    ///   - handler: A handler to execute when the event monitor receives
    ///     an event corresponding to the event types in `mask`.
    init(
        mask: NSEvent.EventTypeMask,
        mode: RunLoop.Mode,
        handler: @MainActor @escaping (_ event: NSEvent) -> Void
    ) {
        self.mode = mode
        self.mask = mask
        self.handler = handler
        self.observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeSources.rawValue,
            true,
            0
        ) { [weak self] _, _ in
            // This observer is installed only on the main run loop.
            MainActor.assumeIsolated {
                self?.processPendingEvent()
            }
        }
    }

    /// Observes a pending event without changing AppKit's queue or its order.
    /// Draining and reposting here can keep a tracking loop awake indefinitely.
    /// See docs/audits/2026-09-20-hotkey-recorder.txt for the captured stack.
    /// https://developer.apple.com/documentation/appkit/nsapplication/nextevent(matching:until:inmode:dequeue:)
    func processPendingEvent() {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        guard let event = NSApp.nextEvent(matching: mask, until: .distantPast, inMode: mode, dequeue: false) else {
            lastEvent = nil
            return
        }
        // AppKit can return a new NSEvent wrapper for every peek. Compare the
        // event values so another run-loop pass does not publish it again.
        if let lastEvent,
            event.type == lastEvent.type,
            event.timestamp == lastEvent.timestamp,
            event.windowNumber == lastEvent.windowNumber,
            event.modifierFlags == lastEvent.modifierFlags,
            event.locationInWindow == lastEvent.locationInWindow {
            return
        }
        lastEvent = event
        handler(event)
    }

    isolated deinit {
        stop()
    }

    func start() {
        guard let observer else { return }
        CFRunLoopAddObserver(
            runLoop,
            observer,
            CFRunLoopMode(mode.rawValue as CFString)
        )
    }

    func stop() {
        lastEvent = nil
        guard let observer else { return }
        CFRunLoopRemoveObserver(
            runLoop,
            observer,
            CFRunLoopMode(mode.rawValue as CFString)
        )
    }
}

extension RunLoopLocalEventMonitor {
    /// A publisher that emits local events for an event type mask.
    @MainActor
    struct RunLoopLocalEventPublisher: @MainActor Publisher {
        typealias Output = NSEvent
        typealias Failure = Never

        let mask: NSEvent.EventTypeMask
        let mode: RunLoop.Mode

        func receive<S: Subscriber<Output, Failure>>(subscriber: S) {
            let subscription = RunLoopLocalEventSubscription(mask: mask, mode: mode, subscriber: subscriber)
            subscriber.receive(subscription: subscription)
        }
    }

    /// Returns a publisher that emits local events for the given event type mask.
    ///
    /// - Parameter mask: An event type mask specifying which events to publish.
    static func publisher(for mask: NSEvent.EventTypeMask, mode: RunLoop.Mode) -> RunLoopLocalEventPublisher {
        RunLoopLocalEventPublisher(mask: mask, mode: mode)
    }
}

extension RunLoopLocalEventMonitor.RunLoopLocalEventPublisher {
    @MainActor
    private final class RunLoopLocalEventSubscription<S: Subscriber<Output, Failure>>: @MainActor Subscription {
        var subscriber: S?
        let monitor: RunLoopLocalEventMonitor

        init(mask: NSEvent.EventTypeMask, mode: RunLoop.Mode, subscriber: S) {
            self.subscriber = subscriber
            self.monitor = RunLoopLocalEventMonitor(mask: mask, mode: mode) { event in
                _ = subscriber.receive(event)
            }
            monitor.start()
        }

        func request(_ demand: Subscribers.Demand) { }

        func cancel() {
            monitor.stop()
            subscriber = nil
        }
    }
}
