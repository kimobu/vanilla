//
//  PanelPresentation.swift
//  Ice
//

/// Owns a panel request from preparation through dismissal, including time spent capturing images.
@MainActor
final class PanelPresentation {
    private(set) var isRequested = false
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    isolated deinit {
        task?.cancel()
    }

    func show(
        prepare: @MainActor @escaping () async -> Void,
        present: @MainActor @escaping () -> Void,
        refresh: @MainActor @escaping () async -> Void = {}
    ) {
        dismiss()
        isRequested = true
        let generation = generation
        task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await prepare()
            guard
                !Task.isCancelled,
                self?.generation == generation,
                self?.isRequested == true
            else { return }
            present()
            // Presenting can synchronously dismiss or replace this request.
            guard self?.generation == generation, self?.isRequested == true, !Task.isCancelled else { return }
            await refresh()
            guard self?.generation == generation else { return }
            self?.task = nil
        }
    }

    func dismiss() {
        generation &+= 1
        isRequested = false
        task?.cancel()
        task = nil
    }
}
