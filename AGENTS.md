# Working on Vanilla

## Communication

- Always use plain English.
- Do not add failure-mode commentary or unsolicited warnings unless explicitly asked.
- Explain what changed and how it was checked. Be precise about what you actually verified.

## Platform direction

- Vanilla supports macOS 27 and macOS 26. Treat macOS 27 as the primary platform and macOS 26 as the minimum supported version.
- Use a stable Xcode release with the macOS 27 SDK for platform modernization. Check the selected Xcode and available SDKs before relying on a new API or compiler feature.
- Build with the newer SDK while keeping a deployment target of macOS 26.0. Guard APIs introduced in macOS 27 with `if #available(macOS 27, *)` and provide working behavior on macOS 26. Use `@available` for declarations that require the newer OS.
- Debug and Release use macOS 26.0 and Swift 6 language mode with complete concurrency checking. Keep both configurations aligned and update the README's supported macOS versions when they change.
- Keep Swift 6 language mode and complete concurrency checking enabled. Make further migration changes in focused, buildable steps; the installed compiler version and the project's language mode are separate settings.
- Remove compatibility code for macOS versions below 26 when updating the relevant area and deployment settings. Check the original workaround before deleting it: an old version check does not prove the underlying issue is gone.

## App identity and documentation

- The app is Vanilla, the repository is `https://github.com/kimobu/vanilla`, and the bundle identifier is `com.kimobu.Vanilla`. Use Vanilla's repository, issues, and releases for app links.
- Ice is the upstream project, created by Jordan Baird. Preserve its copyright notices, acknowledgements, and the README's link to `https://www.buymeacoffee.com/jordanbaird`.
- Use Vanilla in user-facing text and new names. Existing internal names and stored identifiers may retain upstream names; preserve compatibility when changing them.
- Keep the README focused on features, supported macOS versions, setup, updates, and credits. Put development guidance here.
- `docs/` is ignored local working material. Do not link to it from published repository documentation or force-add it without an explicit request. `ROADMAP.md` is the public feature roadmap.

## Repository map

- `Vanilla.xcodeproj`: Xcode project, shared `Vanilla` scheme, and Swift package dependencies. This app is not a standalone Swift package.
- `Tests/`: the `VanillaTests` target and Swift Testing regression tests.
- `Resources/AppIconSource.png` and `Resources/GenerateIcons.swift`: Vanilla's app icon artwork and asset generation.
- `.swiftlint.yml`, `.github/workflows/lint.yml`, and `.github/workflows/build.yml`: lint, build, and test configuration.

The app source directory is `Vanilla/`. The following paths are relative to that directory:

- `Main/VanillaApp.swift`, `Main/AppDelegate.swift`, and `Main/AppState.swift`: app entry point, delegate, and ownership of the main managers.
- `MenuBar/`: item management, sections, appearance, spacing, search, and control items.
- `Events/` and `Hotkeys/`: event taps, event monitors, and keyboard shortcuts.
- `Bridging/`: system API wrappers, private declarations, and Accessibility discovery.
- `Permissions/` and `Utilities/ScreenCapture.swift`: permission handling and menu bar image capture.
- `Settings/` and `UI/`: settings and reusable SwiftUI/AppKit interface code.
- `Utilities/Defaults.swift`, `Utilities/StatusItemDefaults.swift`, `Utilities/MigrationManager.swift`, and `Utilities/PreferenceImport.swift`: saved settings, migrations, and importing upstream preferences.

Read the relevant manager and its callers before changing behavior. Keep changes within the requested scope and preserve existing user settings.

## Swift style and design

- Follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/). Use names and argument labels that make call sites easy to read.
- Follow `.swiftlint.yml` and nearby code: four spaces, the existing file header, and trailing commas in multiline collections. Avoid unrelated formatting changes.
- Prefer `let`, small value types, and enums for a fixed set of states. Use classes where identity, shared ownership, or an Apple framework requires them; mark classes `final` when subclassing is not intended.
- Keep access as narrow as practical. Expose operations or read-only state instead of letting callers mutate a manager's internals.
- Use optionals for absent values and throwing functions for operations that need to explain an error. Avoid new force unwraps, `try!`, and silently discarded errors.
- Keep functions focused. Extract logic when it clarifies behavior or enables a meaningful test; introduce protocols and abstractions for an actual need.
- Explain non-obvious system behavior, ownership, and workarounds in comments. Link the relevant Apple documentation or issue and state which OS versions were verified.
- Use the existing `Logger` categories for diagnostics. Keep captured images, window titles, and other private user content out of logs by default.

## Concurrency and resource ownership

- Follow the [Swift 6 migration guide](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/incrementaladoption/) when changing isolation or language settings.
- Isolate UI state and AppKit operations to `@MainActor`. Give shared mutable caches and services an explicit actor or synchronization owner.
- Prefer structured concurrency. Give long-lived tasks an owner, cancel them when their work is no longer needed, and respect cancellation inside repeated work.
- `Task {}` can inherit main-actor isolation; `async` does not automatically move expensive work off the UI thread. Make the execution context explicit for capture, image processing, and other substantial work.
- Use `Task.detached` only when independent lifetime and isolation are intentional. Pass values that can safely cross the boundary and return UI updates to the main actor.
- Address the underlying isolation problem instead of suppressing diagnostics with `@unchecked Sendable`, `nonisolated(unsafe)`, or broad `@preconcurrency` imports. Any necessary exception must explain its actual synchronization or callback contract.
- Treat C callbacks, event taps, Combine subscriptions, and Objective-C delegates as explicit boundaries. Verify their queue or run loop; a main-queue scheduler is not itself a compiler-checked actor contract. Keep synchronous event-tap decisions synchronous and brief.
- Pair event monitor registration, observers, timers, run-loop sources, and event taps with teardown. Audit `Unmanaged`, Core Foundation ownership, and allocated pointers; release each resource according to its ownership contract.

## SwiftUI and AppKit

- Use SwiftUI for settings and ordinary view composition. Keep AppKit where Vanilla needs precise status-item, panel, window, or event behavior.
- Keep system operations and business logic in managers or services, outside view bodies. View rendering should not install observers, start capture, or change settings.
- Make state ownership explicit. For existing `ObservableObject` models, use `@StateObject` when a view owns the model and `@ObservedObject` when it receives one. Prefer Observation for new models when it fits; migrate existing Combine consumers together with their model.
- Give collection items stable identities. Use bindings for editable state and keep derived state computed where practical.
- Preserve keyboard navigation, accessibility labels, focus, and system appearance behavior. Use semantic colors and materials; check custom menu bar drawing in light and dark appearances.

## Menu bar and system integration

- Prefer public APIs. Keep unavoidable private WindowServer calls and runtime workarounds behind the existing bridging layer; avoid spreading private symbols through feature code.
- Verify private API behavior on both macOS 26 and 27. An availability check for a public API does not establish that a private symbol or undocumented behavior is supported.
- Prefer [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) for new capture work. Before replacing the existing capture implementation, verify that the replacement covers Vanilla's hidden and offscreen menu bar items and composite images.
- Keep Accessibility and screen-capture permission handling in the existing permission flow. Recheck permission state when it changes instead of trusting a permanent cached result.
- Handle display coordinate spaces explicitly: AppKit points, Core Graphics coordinates, backing pixels, and per-display origins are different. Account for a notch, multiple displays, display scaling, and menu bars on different screens.
- Keep event callbacks fast. Prefer event-driven updates and coalesce repeated changes instead of adding frequent polling or rebuilding the image cache unnecessarily. Measure CPU use and allocations for changes to these paths.
- Preserve preference keys, encoded values, and status-item identifiers unless the change includes a migration. Make migrations safe to run again.
- Dependencies currently include Sparkle, LaunchAtLogin, AXSwift, CompactSlider, and IfritStatic. Check their use and compatibility before updating them, and keep intentional resolution changes in `Package.resolved`.

## Build and verification

Run commands from the repository root. Inspect the selected toolchain when doing build or platform work:

```sh
xcodebuild -version
xcodebuild -showsdks
```

Build the app without distribution signing for a compile check:

```sh
xcodebuild -project Vanilla.xcodeproj -scheme Vanilla -configuration Debug \
  -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/Vanilla-DerivedData \
  build CODE_SIGNING_ALLOWED=NO
```

Run the configured lint checks for Swift changes when SwiftLint is installed:

```sh
swiftlint lint --strict
```

- The shared scheme includes the unhosted VanillaTests target using Swift Testing. CI definitions run tests, Debug/Release compilation, and SwiftLint. Do not describe lint or a successful build as app runtime testing.
- Add focused regression tests for changed logic when useful, such as layout calculations, preference migrations, or section state transitions. Prefer Swift Testing for new unit tests and XCTest/XCUITest for UI automation. Wire any new test target into the shared scheme before relying on `xcodebuild test`.
- For platform, build-setting, or dependency changes, also compile Release. A build with signing disabled is a compile check; use an appropriately signed development build for permission and app-integration checks.
- For changed menu bar behavior, exercise the affected actions on macOS 26 and 27: hiding/showing and reordering items, Vanilla Bar and search, hotkeys, permission changes, full-screen Spaces, display changes, and sleep/wake as relevant to the change.
- Check settings persistence across relaunch when settings or state ownership changes. Check idle CPU use when changing observers, event handling, or capture frequency.
- Report the commands run, results, and actual OS versions used for runtime checks. If a tool or OS is unavailable, say which check remains unverified.
- Documentation-only edits need a content and diff check; they do not require an app build.

For platform changes, consult Apple's [macOS release notes](https://developer.apple.com/documentation/macos-release-notes) and the documentation for the specific API being changed.
