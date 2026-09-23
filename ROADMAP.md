# Vanilla implementation roadmap

Proposed September 19, 2026, with progress updates below. This is a backlog, not a release commitment.

The recommended first feature release should remember item placement, offer useful item shortcuts, and make layout and the Vanilla Bar usable without screen recording. Named profiles should follow the saved-layout foundation. Groups, rules, and widgets build on that work.

## Priority and sequence

P0 establishes the supported app and its layout model. P1 is the first feature release. P2 extends organization and automation. P3 is optional later work. Sizes are relative scope estimates: S is a focused addition, M crosses several components, L introduces a subsystem, and research has no implementation estimate yet.

| ID | Work | Priority | Size | Depends on |
| --- | --- | --- | --- | --- |
| V01 | macOS 26/27 baseline and focused tests | P0 | L | — |
| V02 | Remember each item's section and order; place new items | P0 | L | V01 platform findings |
| V05 | Item shortcuts and an auto-rehide shortcut | P1 | S for rehide; M for items | V02 for persistent item bindings |
| V04 | Layout and Vanilla Bar without screen recording | P1 | M | V01 |
| V03 | Automatically hidden menu bars and overflow policy | P1 | Research, then L | V01; V02 for stored priorities |
| V06 | Saved profiles and display-specific selection | P1 | L | V02 |
| V12 | Complete the spacing workflow | P1 | M | V01 |
| V13 | Vanilla releases and automatic updates | P1 | M | V01; release infrastructure |
| V15 | Documentation and remaining branding polish | P1 | S | — |
| V16 | Movement and activation without pointer disruption | P1 research | Research | V01 |
| V07 | Rules for showing items and selecting profiles | P2 | L | V02, V06 |
| V08 | Named item groups | P2 | L | V02, V04 |
| V09 | Spacers, labels, and symbols | P2 | M | V02 |
| V10 | Independent bar/display styles and appearance polish | P2 | M | V01; V06 for profile styles |
| V11 | Shortcuts/App Intents and external automation | P2 | M | V02, V05, V06 |
| V14 | Custom action widgets | P3 | L | V09, V11 |

The auto-rehide shortcut and V15 can ship independently. Start V03 and V16 investigations during V01 so their findings inform the layout design. They do not need to delay unrelated settings or documentation improvements.

## P0: establish the foundation

### V01 — Verify the supported macOS baseline

**Runtime update (September 21):** Swift 6 builds and 86 focused tests pass. Accessibility now supplies item discovery on macOS 26 and 27, and signed builds have passed the recorded desktop and selected full-screen checks. V01 remains open for the remaining permission, movement, capture, input, display, and sleep/wake checks.

Bring Debug, Release, and the README to the intended macOS 26 minimum while developing with the stable macOS 27 SDK. Move toward Swift 6 in focused, buildable changes. Read Apple's [macOS release notes](https://developer.apple.com/documentation/macos-release-notes) and the documentation for each changed API. Follow the existing [project instructions](AGENTS.md).

Inspect the item movement, capture, display-coordinate, and permission paths on both supported OS versions. Determine how macOS 27's own menu bar behavior interacts with Vanilla before choosing new system integration code. A newer SDK alone does not answer that question.

**Completion:** signed development builds exercise hiding, arranging, the bar, search, hotkeys, permissions, full-screen Spaces, display changes, and sleep/wake on macOS 26 and 27. Record the OS/build and result of each relevant check. Add a test target to the shared scheme for layout and persistence logic, plus Debug/Release compile checks in CI. Record idle CPU and memory, capture counts, and movement counts for a repeatable scenario before optimizing.

**Starting code:** [AppState](Vanilla/Main/AppState.swift), [item manager](Vanilla/MenuBar/MenuBarItems/MenuBarItemManager.swift), [capture](Vanilla/Utilities/ScreenCapture.swift), [project](Vanilla.xcodeproj/project.pbxproj).

### V02 — Remember item placement and choose where new items go

Save each recognized item's desired section and relative order. Let the user choose the initial section for previously unseen items. Preserve entries for apps that are not currently running, then apply their saved placement when they return.

Evaluate the existing namespace/title identity against apps with multiple items, changing titles, and items that disappear and reappear. Keep item identity separate from transient window IDs. Introduce a versioned layout model and migration rather than changing existing preference keys in place. Treat a user drag as an update to the saved arrangement; applying an unchanged arrangement should perform no moves.

**Completion:** arrange a mix of single-item and multi-item apps; relaunch the apps and Vanilla; restore the same section and relative order. A newly installed app follows the chosen default. Repeated layout application leaves a settled bar untouched. Tests cover identity matching, returning items, user moves, and repeated migration.

**Starting code:** [item identity](Vanilla/MenuBar/MenuBarItems/MenuBarItemInfo.swift), [item cache and movement](Vanilla/MenuBar/MenuBarItems/MenuBarItemManager.swift), [layout dragging](Vanilla/UI/LayoutBar/LayoutBarContainer.swift), [defaults](Vanilla/Utilities/Defaults.swift).

## P1: finish everyday organization

### V05 — Add useful shortcuts

Add a shortcut to enable/disable auto-rehide using the existing setting. Separately, let a user select an item and assign an action: reveal it, activate it, or open its secondary menu. Reuse `tempShowItem`, `click`, and the existing hotkey recorder. Save item bindings using V02's identity model.

**Completion:** the rehide shortcut updates the visible setting and survives relaunch. An item shortcut still targets the same item after its app restarts. Temporary reveal returns the item to its prior place after interaction. Tests cover action encoding and shortcut conflict handling.

**Starting code:** [HotkeyAction](Vanilla/Hotkeys/HotkeyAction.swift), [hotkey settings](Vanilla/Settings/SettingsPanes/HotkeysSettingsPane.swift), [item operations](Vanilla/MenuBar/MenuBarItems/MenuBarItemManager.swift).

### V04 — Make capture permission optional in more places

Use app icons and labels in the layout editor and Vanilla Bar when captured images are unavailable. Keep captured item images as an enhancement. Reuse search's existing icon fallback and distinguish multiple items owned by the same app. Recheck permission when it changes so the displayed representation updates.

**Completion:** with Accessibility granted and screen recording off, users can identify, arrange, search, and activate supported items. Granting or revoking capture permission updates the views. Verify all paths on macOS 26 and 27.

**Starting code:** [search rows](Vanilla/MenuBar/Search/MenuBarSearchPanel.swift), [layout settings](Vanilla/Settings/SettingsPanes/MenuBarLayoutSettingsPane.swift), [bar](Vanilla/UI/IceBar/IceBar.swift), [permissions](Vanilla/Permissions/PermissionsManager.swift).

### V03 — Handle auto-hidden menu bars and crowded displays

First investigate how to operate when macOS automatically hides its menu bar. Then add an explicit overflow policy: keep selected items visible, send lower-priority items to the Vanilla Bar when space is insufficient, and restore them when space returns. Account for display origin, scale, notch, application-menu width, and the active full-screen Space.

**Completion:** layout and bar access work with the supported auto-hide settings without asking users to permanently change their system preference. On a notched display and an external display, every supported item remains reachable as available width changes. Restored width restores the saved placement. Specify any OS-specific behavior from observed results before implementing it.

**Starting code:** [MenuBarManager](Vanilla/MenuBar/MenuBarManager.swift), [bar](Vanilla/UI/IceBar/IceBar.swift), [layout settings](Vanilla/Settings/SettingsPanes/MenuBarLayoutSettingsPane.swift), [item manager](Vanilla/MenuBar/MenuBarItems/MenuBarItemManager.swift).

### V06 — Add profiles, then match them to displays

Create, duplicate, rename, delete, and manually apply named arrangements such as Work and Presentation. Store item placement and optional appearance selections. Add export/import of a versioned profile file. After manual switching works, allow a profile to be selected for a display or display combination.

**Completion:** two profiles restore distinct arrangements across relaunch; absent apps retain their intended places; export/import preserves a profile. Connecting and disconnecting a configured display selects the intended profile. Applying the already-active profile does not rearrange settled items.

**Starting code:** V02's new model, [settings navigation](Vanilla/Main/Navigation/NavigationIdentifiers/SettingsNavigationIdentifier.swift), [appearance configuration](Vanilla/MenuBar/Appearance/Configurations/MenuBarAppearanceConfigurationV2.swift).

### V12 — Complete spacing controls

Review the existing preference-writing and app-relaunch implementation. Clearly show the selected value and whether it has been applied. Apply/reset should process each eligible app consistently, and explain when the current OS requires a logout. Measure whether a less disruptive application method is available before replacing the current approach.

**Completion:** apply and reset work with multiple app types on both OS versions; the stored value matches the UI after relaunch; the result records which apps were actually processed. Remove the beta label only after these checks.

**Runtime update (September 22):** Apply/Reset, measured spacing, publisher return, and persistence across Vanilla relaunch passed on macOS 26.5 and 27.0. Global values and all app preferences were restored. macOS 27 initially showed empty Layout views before recovery. Timed single- and three-publisher fixture checks subsequently passed in about three seconds; a persistent recovery defect was not reproduced. Vanilla's own spacing updated after relaunch.

**Starting code:** [spacing manager](Vanilla/MenuBar/Spacing/MenuBarItemSpacingManager.swift), [general settings](Vanilla/Settings/SettingsPanes/GeneralSettingsPane.swift).

### V13 — Ship Vanilla updates

Set up Vanilla's own versioning, signed/notarized distribution, release assets, Sparkle signing key, and appcast. Enable the updater only when those exist. Vanilla already installs alongside Ice using `com.kimobu.Vanilla` and imports Ice preferences on first launch; verify that behavior as part of release testing.

**Completion:** install an older signed Vanilla build, update through Vanilla's feed, relaunch, and retain settings. Validate release links and automatic/manual update controls. Never point the fork back at Ice's update feed.

**Starting code:** [updater](Vanilla/Updates/UpdatesManager.swift), [Info.plist](Vanilla/Info.plist), [About pane](Vanilla/Settings/SettingsPanes/AboutSettingsPane.swift).

### V15 — Align the documentation and remaining branding

Replace the search settings button's Ice Cube artwork with the Vanilla mark. Keep the intentionally selectable Ice Cube option. Keep the README's setup instructions and links aligned with the supported OS versions, describe dynamic appearance and existing temporary reveal accurately, and keep this roadmap linked from the README.

**Completion:** inspect the affected UI labels and icon; documentation links resolve; each completed roadmap item points to its implementation and actual verification.

### V16 — Investigate operation without moving the pointer

Bartender 7's documented behavior makes this worth investigating, but its implementation is not established by its marketing. Evaluate public and existing bridging-layer operations for item activation and movement on macOS 27, with separately verified behavior on macOS 26. Test multi-item apps as individual items. Keep activation and rearrangement as separate investigations; one may be possible without the other.

**Completion of research:** a small prototype demonstrates supported operations with the pointer stationary, or a written finding records which operations still need the current method. Only then size the implementation. Do not promise parity based on availability checks alone.

**Starting code:** [move/click operations](Vanilla/MenuBar/MenuBarItems/MenuBarItemManager.swift), [bridging](Vanilla/Bridging/Bridging.swift), [mouse cursor](Vanilla/Utilities/MouseCursor.swift). Comparison source: [Bartender 7](https://www.macbartender.com/Bartender7/).

## P2: add organization and automation

| ID | First useful implementation | Completion evidence |
| --- | --- | --- |
| V07 — Rules | Start with active app, power/battery, and time conditions. A rule reveals chosen items or selects a profile. Let users enable rules, inspect the current match, and choose priority when several match. Add network and Focus integration after their OS behavior is verified. | Simulated condition changes produce one intended action; returning to the previous condition restores the selected behavior. A manual profile choice can suspend automatic switching. Repeated identical events do not cause repeated moves. |
| V08 — Groups | A named group gets its own icon and opens its items in a bar or popover. Users can add, remove, and reorder members without flattening their saved identities. | Group membership survives relaunch; group items remain individually searchable and accessible by keyboard; removing a group returns its members to a defined section. |
| V09 — Spacers and labels | Add movable blank spacers with adjustable width, plus text/emoji/symbol labels. Save them as Vanilla-owned items with persistent identifiers. | Add, resize, move, remove, and restore these items within profiles. VoiceOver announces meaningful labels. |
| V10 — Appearance | Separate Vanilla Bar styling from menu bar styling; optionally attach styles to displays/profiles. Retain existing light/dark colors. Work with macOS's background setting. Treat whole-display corner rounding as a separate optional feature. | Bar styles can differ from the menu bar; display changes select the right style; light/dark changes preserve user choices. Investigate per-Space styling separately before committing it. |
| V11 — External actions | Expose list-items, reveal/activate-item, toggle-bar, and apply-profile through App Intents/Shortcuts. Add AppleScript only for workflows that need it. Reuse the same operations as the UI. | A Shortcut selects an item, activates it, and applies a named profile. Calls made while Vanilla is already moving items produce a defined final arrangement. |

Start V07 in a dedicated rule manager, using event-driven condition providers and the V02/V06 operations. V08/V09 should use new models built on [ControlItem](Vanilla/MenuBar/ControlItem/ControlItem.swift), not extend the fixed section enum with every user-created item. V10 extends the [appearance manager](Vanilla/MenuBar/Appearance/MenuBarAppearanceManager.swift). V11 wraps existing operations rather than putting system logic in the intent declarations.

## P3: consider after the core release

**V14 — Action widgets:** begin with a custom label/icon that opens a URL or runs a Shortcut. Reuse V09's owned-item model and V11's actions. Add refreshed data or scripts only with a defined update interval and an owner that stops work when the widget is removed. Completion means widgets can be created, edited, removed, restored, and activated from the keyboard.

**Command search:** once profiles and rules exist, extend the existing search panel to find and run them. Clipboard history and a Top Shelf equivalent are separate product categories; defer them unless Vanilla deliberately expands beyond menu bar management.

## Recommended first implementation

Begin V01's platform checks and V02's saved-layout design together. Ship the small auto-rehide shortcut independently. Follow with persistent item shortcuts and the app-icon fallback for layout and the bar, then manual profiles. This order gives users visible improvements while establishing the data model needed by groups and automation.
