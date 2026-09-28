# Tether app contributor guide

## What this repository is

Tether is a native macOS SwiftUI client for Claude Code. It is intentionally a thin client: it presents hosts, sessions, streamed transcript items, prompts, and settings while `../tether-server` owns Claude Agent SDK queries and long-lived session state.

This repository builds on its own. Clone it, open `Tether.xcodeproj`, and build:

- `TetherKit/Package.swift` depends on the `TetherProtocol` package published by `AFRUITPIE/tether-server`, pinned by version. The generated sources are committed there, so nothing has to be generated to consume them.
- The app target's build phase (`Scripts/fetch-server-binaries.sh`) puts the standalone server binaries in the bundle, downloading the pinned version's GitHub release once and caching it under `DERIVED_FILE_DIR`.
- `.tether-server-version` is the pin. Bump it when the app needs a newer server, after that version has been released.

`tether-server` is public, so SwiftPM can resolve the protocol package without credentials. The app repository remains private.

### Local development (both repositories side by side)

With a `tether-server` checkout beside this one, the app builds against it and no release is involved:

- `TetherKit/Package.swift` takes the protocol package from `../tether-server` by path, so a protocol change is seen on the next build, in Xcode and in `swift test` alike.
- The build phase compiles that checkout (`mise run compile -- --dev`) whenever its sources changed since the last dev build. Dev builds are versioned `<version>-dev.<time>`, so the running daemon replaces itself on the next connect, and `Bootstrap` deletes older dev builds from `~/.tether/bin` (and on SSH hosts).
- A path dependency has no pin, so SwiftPM empties `Package.resolved`. Both copies are marked `git update-index --skip-worktree` in this clone so that churn stays out of commits; `--no-skip-worktree` before bumping the pin.
- The server's manifest names its package `tether-server`, the same as the folder: Xcode keys a local package by that name and a remote one by the folder-derived identity, and the product lookup fails when they differ.
- `TETHER_USE_RELEASE=1` (for SwiftPM and the build phase) uses the published package and the pinned release instead, which is what CI and a fresh clone get.

Work on local branches and commit there; releases, pin bumps and PRs happen together when the owner asks to ship: release the server, bump `.tether-server-version` and the pin, then open the PRs.

## Repository map

- `Tether.xcodeproj`: macOS app target, shared `Tether` scheme, signing, and the server-binary copy phase.
- `Tether/TetherApp.swift`: app entry point, the chat window group (one `WindowTarget` value per window), commands, settings scene, the host windows (Plugins, Scheduled Tasks, Connection Log), and the debug-only `TETHER_OPEN_THREAD` launch hook.
- `Tether/TetherIntents.swift`: the Start a Chat shortcut (App Intents live in the app target), which opens a `tether://` link (`OpenURLIntent`).
- `Tether/Info.plist`: the `tether` URL scheme.
- `TetherKit/Sources/TetherKit`: transport and state layer.
  - `Bootstrap.swift`: selects a bundled binary, installs it locally or over SSH, and builds the `tether connect` command.
  - `Transport.swift`: process-backed JSONL byte transport.
  - `RPCClient.swift`: actor that correlates JSON-RPC calls, streams notifications, and answers server-to-client requests.
  - `HostConnection.swift`: one host connection, reconnect/replay behavior, catalogs, thread operations, and server-request routing.
  - `ThreadModel.swift`: `@MainActor @Observable` reducer for one thread.
  - `TranscriptRows.swift`: pure folding of transcript items, including compact tool-call groups, what goes between turns (dates above prompts, a turn's edited files), and Previous/Next Prompt's targets.
  - `TurnEdits.swift`: a finished turn's file edits, counted from its Edit/MultiEdit/Write/NotebookEdit inputs (`LineDiff`, which `DiffView` draws with too).
  - `PreviewSupport.swift`: debug-only sample state used by Xcode previews.
- `TetherKit/Sources/TetherUI`: views and app-level state.
  - `AppModel.swift`: hosts and their connections, what a new window opens on (`newWindowTarget`), drafts, and persisted preferences.
  - `WindowModel.swift`: one window's host, chat, inspector and New Chat draft, and `WindowTarget`, the window's scene value. Each window has its own; commands reach the frontmost through `@FocusedValue(\.window)`.
  - `TetherLink.swift`: `tether://` links (a chat, or New Chat with a directory and prompt), what reaches the app from outside a window.
  - `Appearance.swift`: the General and Advanced settings views read, as one `Codable`, `Equatable` value in the environment.
  - `Attention.swift`: notifications (with Allow/Deny on permission requests), the Dock badge and menu (SwiftUI, in an `NSHostingMenu`), VoiceOver announcements, Settings ▸ Notifications' preferences, and the app delegate.
  - `Secrets.swift`: hosts' environment values, kept in the Keychain rather than the defaults file.
  - `OpenFiles.swift`: Settings ▸ General ▸ Open Files With — the editors it offers (by bundle id, installed ones only) and opening a file in one.
  - `RootView.swift`: the shell only — split view, the one toolbar, the one inspector, View-menu commands.
  - `Sidebar/`: one host's chats, and `HostCommands` (the Host menu); `SidebarSections.swift` is the pure, tested grouping (Pinned, then date or directory; or Activity's Needs You, then days).
  - `Toolbar/`: `SessionControls` (the model, effort and permissions menus over one `SessionSettings`, live chat or draft, and the Chat menu) and `ReservedWidthLabel`.
  - `Inspector/`: the tabbed shell (`InspectorTabs`, SwiftUI's `TabView`), its toolbar toggle, and one view per pane (`TasksPane`, `SessionPane`, `MCPPane`, `ChangesPane`).
  - `Thread/`: `ThreadView` (transcript over bottom bar), `TranscriptView`, `BottomBar`, `Composer` (`/` commands, `@` files, images), `ConnectionStatusCard` (in the field's place while the host isn't connected), `ArrivingText` (streamed text fading in), `TranscriptFind`, `PromptNavigator` (Chat ▸ Previous/Next Prompt), `TurnEditsView`, `DateSeparatorView`.
  - `NewChat/`: the new-chat screen (directory, branch and Work In above the composer), and Choose Directory… (`DirectoryChooser`: the open panel on this Mac, the remote picker, a navigation stack of `fs/list` pages, elsewhere), which Scheduled Tasks uses too.
  - `Scheduled/`: a host's Scheduled Tasks window (Host ▸ Scheduled Tasks…), over the daemon's `schedule/*` methods.
  - `Plugins/`: a host's Plugins window (Host ▸ Plugins…), over the daemon's `plugin/*` methods (the host's `claude plugin`). A grouped Form, not a List: an inset List trapped in SwiftUI's outline code on its rows.
  - `Settings/`: General, Notifications, Hosts and Advanced panes, host detail, the environment sheet, and the connection log window.
  - `PromptViews.swift`: permission, question, plan, and elicitation requests.
  - `ItemViews.swift`, `ToolCallView.swift`, `Markdown.swift`: transcript rendering. Markdown's blocks are parsed by the app, inline styling by `AttributedString(markdown:)`: Foundation's `presentationIntent` drops a numbered list's own numbers and can't parse the streamed tail on its own the way `MarkdownCache` does.
- `TetherKit/Tests/TetherKitTests`: transcript folding and opt-in live-server coverage.

## Runtime flow

1. `AppModel` creates a `HostConnection` for each configured host and initiates connections.
2. `HostBootstrapper` finds the matching `tether-<version>-<platform>` binary, installs it under `~/.tether/bin`, and launches `tether connect` locally or through system `ssh`.
3. `RPCClient` performs the initialize handshake and carries newline-delimited JSON-RPC.
4. `HostConnection` loads the host catalog, maps summaries to stable `ThreadModel` instances, subscribes with `afterSeq`, and batches streaming deltas to roughly one UI update per frame.
5. `ThreadModel` applies snapshots and notifications. SwiftUI renders its cached top-level items, rows, turns, tasks, pending requests, and status.

The daemon, not the app, owns live Claude queries. Closing or disconnecting the app must not end a turn. Reconnection must resume from the last sequence number and reload history only when replay reports a gap.

## State and concurrency invariants

- `RPCClient` is an actor. UI stores are `@MainActor @Observable`; keep network/process work off the main actor and UI mutations on it.
- Do not create or insert observable models from a SwiftUI `body`. Resolve selections when state changes, then render existing models.
- Keep one `ThreadModel` identity per `(host, threadId)`. Replacing it loses subscriptions, pending prompts, and scroll continuity.
- A thread opened before its host connects is deferred through `openRequested`; do not turn that normal race into a permanent “Not connected” error.
- Apply `historySeq`, `lastSeq`, and `afterSeq` consistently. A history snapshot and its live tail must neither overlap nor leave a gap.
- Server requests can be answered by more than one attached client. Preserve the once-only continuation guard and remove prompts on `serverRequest/resolved`.
- Streaming deltas are intentionally coalesced. Do not reintroduce one full transcript invalidation per token.
- A `ForEach` element is exactly one view, so SwiftUI counts elements without building them: a row whose body could be none or several (a `Group` around a `switch`, an `EmptyView` case) is wrapped in a stack. Check with the launch argument `-LogForEachSlowPath YES` and `log show --predicate 'subsystem == "com.apple.SwiftUI"'`; what's left at launch (`Range<Int>`, `SubviewsCollection`, `StackItem`, `Effect`) is SwiftUI's own.
- Keep expensive derived work out of view bodies. Transcript rows, child lookup, Markdown parsing, and diffs have caches for a reason.
- `ThreadModel.title` and `taskEntries` are stored, not derived from `items`: anything the sidebar, toolbar or inspector chrome reads must not change per streamed delta. Only `TranscriptView` and its rows read `rows`/`items`.
- A view takes the narrowest model it needs, and each inspector pane is its own view, so a delta redraws at most the transcript and the open pane.
- State that changes every frame of a resize or an animation (the transcript's scroll position) lives in a view whose body holds no rows: `TranscriptView` owns the scroll state and `TranscriptContent` the rows. Environment values are compared by value, so one that holds a closure is `Equatable` by its owner (`InspectSubagentAction`); a new closure on every shell update redrew every tool call.
- Persisted preferences are plain stored properties on `AppModel` saved through `Stored`. No `@AppStorage` inside an `@Observable`.
- Composer drafts (`AppModel.drafts`) are not observed and are written a second after typing pauses (and on quit): observed, every keystroke redrew every composer in every window. A composer reads its draft when it appears; text put in from outside (Shortcuts' Start a Chat) goes through `deliverDraft`, a token each composer showing that key applies once.

## UI and HIG decisions

The product should feel like a standard current macOS app. Prefer native SwiftUI components and behavior over custom chrome. Check the relevant Apple Human Interface Guidelines and API documentation for every interaction or presentation change.

- Target the current project baseline (Xcode 27, Swift 6, macOS 27+). Do not add compatibility shims for older systems unless requested.
- Let system layout and intrinsic sizing work: a row of buttons that may not fit is a `ViewThatFits` (the plan card's stack at the trailing edge), something centered on an edge uses an alignment guide (the hover bar), a list's markers share the width of its widest, a bar over a scrolling form is a `safeAreaBar`, and `fixedSize` holds only the axis that must hold. Avoid hand-computed geometry, arbitrary fixed production sizes, and `.fixedSize()` as a general layout repair. Fixed frames in previews and small icon/status geometry are fine.
- Liquid Glass belongs to controls: toolbar controls, composer, and prompt cards. Transcript content uses ordinary fills, and the status strip (information, not a control) the bar material. Never stack glass on glass; controls inside a glass card use standard bordered styles. Glass that comes and goes does it the glass's way: a prompt card and a suggestion `materialize`, and the connection card and the message field share a `glassEffectID`, so one morphs into the other. Dimming goes on the content under the glass, never after `glassEffect`. Cards share one corner radius (`Layout.cardCornerRadius`). Colors are semantic styles (`.fill`, `.tint`, `.windowBackground`).
- The shell is `NavigationSplitView` + one `.toolbar(id:)` on the detail container + one `.inspector` on the split view, presented only when Settings ▸ Advanced ▸ Inspector puts it Beside the Chat. No `GeometryReader`, preference keys, `columnVisibility` bindings, or `.id()` on containers other than `ThreadView(...).id(thread.id)`, and that one stays inside `DetailView`'s `ZStack`: when the detail column's root view changes identity, SwiftUI rebuilds the column's toolbar items and they fade in on every chat switch.
- Every toolbar item is unconditional: never an `if`/`switch` around a `ToolbarItem`. Something unavailable is disabled, not removed, so nothing moves when the selection or a column changes. The toolbar is user-customizable (`ToolbarCommands`).
- Settings ▸ Advanced ▸ Show Panes In places Tasks/Session/MCP/Changes: Inspector (the default: SwiftUI's `.inspector` on the split view), Tabs (a `TabView` at the window's root, which macOS shows in the toolbar: the split view is the Chat tab, each pane a whole-window tab; the inspector's shown state and pane are the selection, and there's no inspector or its button), Floating Panel (a `UtilityWindow` showing `AppModel.activeWindow`'s chat, since a panel doesn't get the main window's focused values; it hides while the app is inactive), Drawer (a `VSplitView` under the chat in the detail column) and Card Over the Chat (a glass card placed by ThreadView and NewChatView before their bottom bars, so it clears the composer). `WindowModel.inspectorShown` is the one switch: the panel's state is the app's, the rest are each window's. Outside Tabs the inspector's toolbar button stays, and its symbol says where the panes open. Every placement but Tabs shows the panes as SwiftUI's own `TabView` in its default style (`InspectorTabs`): a tab bar across the top of the pane, inside the inspector, read by VoiceOver as tabs. Its tabs show their titles, not their symbols. Not a picker in the toolbar, where every change of tab made AppKit lay the whole toolbar out again (about 50 ms/s more when switching panes), nor a hand-made bar: `TabView` did less main-thread work per switch than a glass capsule of buttons (`.grouped` boxes the pane in the old bordered look, and `.sidebarAdaptable` puts a list inside the inspector).
- Use SwiftUI's own components as they come. The inspector column is the stock `.inspector` on the split view (`inspectorColumnWidth(min: 260, ideal: 300, max: 420)`). On macOS 27 it keeps the window at least as wide as its columns while it's open (the window can grow but not shrink until it's closed). Every override tried to let it shrink — an explicit window minimum, a minimum that drops while it opens, ideals set to the minimums, opening it after launch, a detail-column minimum that grows with it — let the window shrink under the columns and clipped the sidebar and the inspector at both edges, or sent AppKit into its Update Constraints loop. The cause is SwiftUI's: `.inspector` wraps the whole split view in a split pane and takes that pane's minimum from AppKit's fitting size of the nested split view, which is its current size. It's SwiftUI's to fix; a custom column that avoided it was tried and rejected in favor of the native one. The other placements exist so the chat's width need not change at all.
- The window's minimum width is 740 (sidebar 220 + detail 520, which keeps every toolbar control out of the `»` overflow) while the inspector column is closed, and none while it's open (see above). The detail column declares its minimum (`navigationSplitViewColumnWidth(min: 520)`): without it the split view's minimum didn't count the detail, so opening the inspector in a narrow window didn't widen it and the inspector spilled past the window's edge. The Settings window's sidebar has no toggle (`.toolbar(removing: .sidebarToggle)`), as System Settings' doesn't.
- The transcript follows its end until the reader scrolls away. A resize, or the inspector or sidebar opening, re-measures every row; it must not count as scrolling away (`followsEnd` in `TranscriptView`).
- Toolbar, leading to trailing: sidebar toggle, New Chat (always visible; `Command-N` too), title and subtitle, then model, effort and permissions (one `.primaryAction` item, trailing, so the title keeps the space), then the inspector toggle. The three are a `ControlGroup` in the navigation style, so they share one glass capsule with dividers (the default style gave each its own) and Customize Toolbar and the » menu call them Session; `.menuIndicator(.visible)` keeps their chevrons. They stay in the toolbar: putting them in the message field was tried and dropped. New Chat and the session item have `.visibilityPriority(.high)`, so the title truncates before either goes to the » menu. Never change which menus one toolbar item holds: that tripped an AppKit toolbar assertion (`_currentItems`); and `toolbarItemHidden` hid nothing on macOS 27. Effort and permissions follow the toolbar's display mode (icon only by default); the model's label is title and icon, set on the label, since a label style on a `Menu` reaches its items too.
- The subtitle is the chat's directory name (the New Chat draft's on New Chat), prefixed by the host when more than one is configured. The full path is in the Session pane, or the directory menu on New Chat.
- Model, effort and permissions are three pull-down menus with inline pickers: the model by name (Fast Mode is a toggle in its menu), effort as a gauge that follows the level, permissions as the mode's symbol (red for bypass). Not pop-ups: an icon-only pop-up shows its rows as bare symbols. Each label reserves the width of its widest value (`ReservedWidthLabel`), so choosing among them never resizes a control. Bypass Permissions is listed only with Settings ▸ General ▸ Offer Bypass Permissions (off by default, as in Claude Code) or while it's the mode in use; the permissions label reserves its width either way. Settings uses the same symbols and labels; the mappings live in `Helpers.swift`.
- Each permission mode has a one-line subtitle saying what it does (`PermissionMode.summary`, beside the labels and symbols). The toolbar menu and the Chat menu list the modes as Toggles bound to the selection (`PermissionModeItems`), because a Picker's rows become menu items without their second `Text` while a Toggle's becomes the item's subtitle (`PermissionMenuItemsTests` reads the menu SwiftUI builds). Settings and a scheduled task keep a pop-up, whose rows can't carry one, and show the chosen mode's line under the row's title (`PermissionModeFormPicker`).
- Windows are SwiftUI's: one `WindowGroup(for: WindowTarget.self)`, whose value is the window's host and chat, kept current as the window changes, with the inspector in `@SceneStorage`. The system restores them as the person's "close windows when quitting" setting says; `.defaultLaunchBehavior(.presented)` covers a launch with nothing saved, and the app delegate opens one after restoration when saved state held no window (`didFinishRestoringWindowsNotification`). A value names a chat by host and thread, so opening one already on screen brings its window forward; New Chat's values never match. The first window of a launch opens on the last chat, later ones on New Chat. Window tabs are the system's.
- Anything from outside a window — a notification, the Dock menu, Shortcuts, Scheduled Tasks' Open — is a `tether://` link opened with `openURL`. The main scene handles every link, each window prefers its own chat's (`handlesExternalEvents(preferring:allowing:)`), and the host windows none. Any app or web page can open one, so a link that sends its prompt must carry a token from `TetherLink.authorizeSend()`, which only this process has; without one it fills in New Chat and waits.
- File ▸ New Window is ⌥⌘N, the app's own item in place of SwiftUI's (`CommandGroup(replacing: .newItem)`): the scene's `keyboardShortcut` left SwiftUI's on ⌘N, which is New Chat. Chat ▸ Next Chat and Previous Chat are ⌥⌘] and ⌥⌘[ (⌃⇥ is Show Next Tab).
- Every toolbar control is also in the menu bar, since the toolbar can be hidden or customized: File ▸ New Chat, the Chat menu (model, Fast Mode, effort, permissions), and View (sidebar, inspector panes). A menu shortcut must not take one the system's menus use: Ask a Side Question… is ⌥⌘;, since ⌘; is Check Document Now.
- The inspector is full-height, attached to the split view, and present on every screen (`No Session` on New Chat, with the tabs still over it). Its toggle is a plain button declared in the inspector's own toolbar, so it sits above the column and never tints. `Tasks` is the first tab and the default. View ▸ Inspector repeats the panes (⌥⌘1–4 always show theirs); ⌥⌘I shows or hides it on the last pane.
- Changes is the working tree against the last commit (`git/status`, `git/diff`, untracked files read whole), refreshed after each turn. The diffs are parsed off the main actor (`UnifiedDiff.workingTree`), keeping at most 5,000 lines a file and 1,000 characters a line (the rest counted, and said), and a file shows its first 300 lines until Show All. A click on a line (a button) leaves a comment, in a popover beside it; the comments go to Claude as one message (Send Comments; no ⌘Return, which belongs to the message field). On this Mac a file row offers Open (on hover, and in its context menu with Show in Finder).
- Open, for a tool call's file or a Changes row, uses Settings ▸ General ▸ Open Files With (Default App, or an installed editor), and only on this Mac; so does a link in a reply that names a file, relative to the chat's directory (`OpensFileLinks`, the transcript's `openURL`). On this Mac a file row drags out as the file.
- Archive, Unarchive, Pin and Rename register with the window's undo manager, so Edit ▸ Undo takes them back; ⌫ on a selected chat archives it, as Mail's does.
- The sidebar shows one host, chosen from the Host menu in the menu bar (hosts, Connect/Reconnect, Manage Hosts…). It is not a toolbar control: it changes only when switching sessions, and the subtitle names it whenever more than one host is configured. Switching host opens New Chat on it. Chats are grouped by date or by directory (View menu and the list's context menu), most recent first, using Claude's generated session title when available. Connection states are an overlay, not rows.
- Pinned chats (Chat ▸ Pin, ⌥⌘P, or the row's context menu) are listed in Pinned above the grouping, most recent first, and not repeated below. Pins are this app's, per host (`AppModel.pinnedChats`), not the host's; an archived chat keeps its pin but leaves Pinned until it's unarchived. Grouped by directory, a section shows New Chat Here on hover (`sectionActions`) and has a context menu (New Chat Here, Show in Finder on this Mac, Archive Chats in Directory, which archives what's listed under the header without asking, since Edit ▸ Undo brings it back). A row swipes from the trailing edge to Archive or Unarchive, as in Mail.
- Settings ▸ Advanced ▸ Sidebar ▸ Activity is the alternative layout: Needs You on top, then every chat by day (Today, Yesterday, the weekday, then the date), each row with its directory on the title's line and the latest reply below. The reply is `ThreadModel.replyPreview`, stored when a reply completes (never per token) and kept after the transcript is let go; `thread/list` carries no preview, so only chats loaded this launch show one. Group By and Pinned don't apply there; a pin is a glyph on the row.
- New Chat has no form: one row of plain borderless menus sits above the composer, where a chat's status strip goes, so nothing scrolls under the toolbar and the detail column looks the same as a chat's. Not glass, since the composer under them is. The row is the directory (recent directories, Choose Directory…), the branch checked out there (read-only, from `git/status`, only in a repository), and Work In (This Directory or New Worktree, starting from Settings ▸ General ▸ Start in a New Worktree). Work In is last: its label changes width with the choice, since a menu button's label can't reserve width the way a toolbar item's does, and nothing should move when it does. A host that isn't connected shows the status card in the composer's place, as a chat does, and hides the row until it is.
- The composer stays mounted under a pending prompt (Send disabled) so a draft survives it. A prompt card's default button is the window's default only while the message field doesn't have focus (`composerHasFocus`): a default button takes Return from the whole window, and Return in a draft would otherwise have pressed Allow. The field takes focus by `defaultFocus`, when the window opens or focus has nowhere else to go, never from the sidebar or search.
- While the host isn't connected (disconnected, connecting, failed), the composer's field row is a status card (`ConnectionStatusCard`): "Not Connected", "Connecting…" or "Couldn’t Connect", the host's name or the failure's reason, and Connect or Reconnect (nothing while connecting). Glass, as a control card; its button is `.bordered`. The composer stays mounted behind it, so the draft and attachments come back with the field. It's said once: the transcript's placeholder shows nothing while the host is down, and New Chat has no overlay.
- The composer is laid out like Messages: a round + (a menu: attach, mention, commands) beside a capsule field with a round Send or Stop inside it, on the last line's baseline, so one line sits level with Send and Send stays by the last line as the text grows. The + is a `Menu` with glass on its label: the glass button style draws a flat circle on a `Menu` on macOS 27. Nothing else sits in the field: how full the context is lives in the Session pane. Return sends and Shift-Return starts a line (or ⌘Return sends, per Settings); Esc closes an open `/` or `@` list first, and otherwise stops a running turn, as Chat ▸ Stop (⌘.) does. Files and images come in through one `Transferable` (`Composer.Incoming`): dropped on the field (outlined while a drag is over it), pasted, or from Continuity Camera; a directory dropped on New Chat's field is where the chat starts. Shift-Return puts its new line at the cursor (the field's `TextSelection`).
- A finished turn that edited files ends with one quiet row after its last reply: "Edited 3 files" and "+42 −7" (the diff colors), counted from the turn's own Edit/MultiEdit/Write/NotebookEdit inputs — a subagent's included, failed calls not — never the working tree (`TurnEdits`). Open, one line per file (name, directory, counts), each opening to its edits in `DiffView`, and Restore Files…, which is Restore Code to Here… for the turn's prompt. No Undo. Summarized in `ThreadModel.rows(_:)`, cached with the rows (each finished call's changes memoized), in every Tool Calls mode; never for the running turn.
- The date goes above a prompt, centered and quiet, as Messages does: the first prompt shown, a prompt on a new day, or one more than an hour after the last item (`DateSeparators`, a row of its own). "Today 2:14 PM", "Yesterday …", the weekday within the week, then the date, in the reader's locale (`TranscriptDate`).
- Chat ▸ Previous Prompt and Next Prompt (⌥⌘↑ and ⌥⌘↓) bring the reader's own prompts (the date above one, when it has one) to the top of the transcript, from the prompt last gone to until the reader scrolls for themselves (not until it's on screen: a quick second press came before the scroll landed and went back to the same prompt), else the topmost row on screen; Next past the last goes to the end, and Previous before the first loaded prompt loads older pages until one has a prompt. Not ⌘↑/↓ or ⌃⌘↓: text fields use those, and the composer usually has focus. The rows on screen come from `onScrollTargetVisibilityChange`, kept in an unobserved box so scrolling redraws nothing.
- A symbol that changes turns into the next (`contentTransition(.symbolEffect(.replace))`): the effort needle, the permission mode, Send and Add to Turn, a to-do's status, the sidebar's status glyph. Pinning animates the row into Pinned.
- Motion is quick and says what happened: a prompt just sent springs up from the composer into its bubble (`UserMessageView`, from `ThreadModel.sentAt`, which this app sets when it sends; drawn with scale and offset, never laid out, and not for history or other sessions), Send springs up as it sends and trades places with Stop, Copy turns into a checkmark for a moment, and a message's hover bar fades in. None under Reduce Motion where it moves anything.
- VoiceOver: the transcript has a Prompts rotor (which reaches rows the lazy stack hasn't built) and is labelled Transcript; dates are level-1 headings and a reply's headings sit under them; a reply is one element named Claude, as a prompt is You, with when it was sent as custom content; a prompt card is a labelled container whose heading takes VoiceOver focus when it arrives; a side question's answer and where Find Next landed are announced; a request is announced before what's being read, a finished reply after it (`accessibilitySpeechAnnouncementPriority`). Code, diffs and logs are marked as code or console text, diff lines say Added or Removed, and a status that's a glyph or a color is said in words too. Spinners and images have labels; a button repeated per item names its item.
- A context menu is never the only way to a command. A message's actions (Copy, Fork from Here, Restore Code to Here…) are also on a bar that appears on hover, with the time it was sent, and are VoiceOver actions; right-clicking the words themselves gives the text's own menu.
- Settings apply immediately; text fields commit on Return or focus loss. No Save/Revert.
- A confirmation is a `confirmationDialog` presenting what it acts on (`presenting:`), a sheet is `sheet(item:)` where it shows something; no Bool built from an optional to present with. Something gone for good (Delete a chat or a scheduled task, Remove Anyway on a worktree) is `role: .destructive` with `.dialogSeverity(.critical)`; Uninstall and Remove Host are destructive only. Severity and suppression are environment values that reach every dialog inside where they're set, so such a dialog sits on a `.background` view of its own. The worktree offer after archiving has Don't Ask Again (`dialogSuppressionToggle`), which Settings ▸ General ▸ Offer to Remove Worktrees turns back on.
- Sheets size themselves (`presentationSizing(.form)`, fitted vertically when short) and put Cancel and Done in the `cancellationAction` and `confirmationAction` placements; no fixed frames or hand-built button rows. File dialogs say what they do (`fileDialogConfirmationLabel`) and start in the chat's directory.
- Rename is in place on the row from its context menu (`RenameButton` and `renameAction`), as Finder renames; Chat ▸ Rename… keeps an alert, since the sidebar may be hidden.
- A local chat's directory is the window's proxy icon (`navigationDocument`, set by `ThreadView`, whose identity changes with the chat, not the shell's).
- The Tasks pane's detail has its own back button: a `NavigationStack` in the inspector put its Back button in the window's toolbar, over the chat.
- Settings uses a General/Notifications/Hosts/Advanced sidebar; the Hosts pane selects a host above its detail form.
- Few settings. A behavior gets a setting only when people genuinely differ on it (Send With, reading width); otherwise pick the sensible behavior. Settings ▸ Advanced holds only the layouts still being compared (tool-call display, and where the panes go), so the owner can switch between them in the running app; keep each side working and previewed, and remove the losers once one is chosen. Every setting lives in `Appearance`, read from the environment where it's drawn, with its own `decodeIfPresent` so older stores keep their other choices.
- Numbers, durations, costs and weekdays go through `FormatStyle` and the calendar (`Format`), never `String(format:)` or English names; counts inflect (`^[…](inflect: true)`). View ▸ Bigger scales the system text styles with `Font.scaled(by:)`.
- Copy is terse and title case. Say "directory", never "folder" (Show in Finder keeps Finder's name). An empty state is a title; add a description only when it says something the title doesn't and the user can act on it. Never show raw enum or wire values.
- Prompt suggestions are buttons above the composer, not text inside its glass field.
- Transcript and composer share the selected reading width: Narrow (default), Medium, or Wide.
- Do not show reasoning/“Thought” content. A quiet “Thinking…” line may mark the interval before visible output; it disappears once a message or tool call is present.
- Every row that opens (a call, a run of calls, a turn's work, a turn's edits and each file) is a `DisclosureGroup` in `TranscriptDisclosureStyle`: the chevron at the trailing end, nothing indenting, and VoiceOver told whether it's open.
- Finished adjacent tool calls fold into one line that says what they did ("Read 2 files, searched code, and ran a command", `ToolCallText`), failed, denied and stopped calls included. Running work stays individually visible. Settings ▸ Advanced ▸ Tool Calls compares this with Worked For (a finished turn's work behind one "Worked for 3m 12s" line above its last message) and Every Call. Find in Chat is a bar over the transcript (no system find bar serves a read-only transcript): its field takes the keyboard by `defaultFocus` when ⌘F opens it, and Esc within it closes it (`onExitCommand`), leaving Esc in the message field to stop a turn. Edit ▸ Find ▸ Search Chats (⌥⌘F) puts the keyboard in the sidebar's search (`searchable(isPresented:)`). Find in Chat searches exactly the rows the transcript shows (`thread.rows(folding)`); a match behind a fold is the fold's row, which opens when it's the current match, along with a run inside it that holds the match.
- Errors are quiet. An agent's missteps are ordinary and it usually recovers, so a failed call, an error item or a failed turn is gray text with a plain glyph and the first line of the reason, never red: a fold says "1 failed" in gray beside its chevron. Red is kept for danger (Bypass Permissions) and diffs. Subagents and workflows belong primarily in the Tasks inspector.
- A tool row is words first, starting at the reply's leading edge: a verb in the tense its status calls for, then what it acted on (a file's name, a command's first line), with no kind icon, and the status (spinner while running, a gray glyph when it went wrong) and the disclosure chevron at the trailing end. Expanded runs and detail keep the same leading edge; nothing indents. A running call's spinner is hidden from accessibility and its row says "Running" as its value; otherwise the row reads as a progress indicator.
- Streamed text fades in: only the last block of the reply being streamed into (`ThreadModel.streamingReplyID`, stored, set when a top-level reply starts and cleared when it completes or its turn ends) uses `ArrivingText`, and it redraws per frame only while a piece is fading. Every settled reply, and every code block, is plain `Text`: a fade on each reply's last block put a `TimelineView` and a task in every message of a long chat. The transcript glides to its end as a reply wraps by drawing the content offset (`visualEffect`, not `offset`, which re-lays out the lazy stack) while the scroll view's own anchor holds the end. Don't switch `defaultScrollAnchor` during layout: AppKit throws.
- Worktrees: New Chat can start a chat in a new git worktree (`thread/start`'s `worktree`, made by the daemon under `<repo>/.claude/worktrees/`). Archiving or deleting such a chat offers to remove the worktree — only Tether's own, `.claude/worktrees/tether-<8 hex>` (`WindowModel.tetherWorktree`), never Claude Desktop's beside them — asking again before discarding uncommitted changes (`RPCError.worktreeDirty`) or a branch's commits merged nowhere else (`worktreeUnmerged`), and saying why when removal fails.
- Scheduled tasks live in the daemon, which runs them while no app is open; the app only edits them. Each run is a new chat.
- A plan's usage limit (`thread/rateLimit`) is said in the status strip only once it's near or reached; the Session pane shows the gauge.
- Notifications are for a chat you aren't looking at: a finished reply (per Settings), and a request, whose notification has Allow and Deny. A request is told about once, though the daemon re-sends a waiting one on every reconnect (`RequestSightings`); its notification is withdrawn when it's resolved anywhere (`tetherRequestResolved`), and Allow or Deny on one answered since quietly says Already answered. A chat on screen gets a VoiceOver announcement instead. UI tests never reach Notification Center.
- A running task's detail in the Tasks inspector offers Stop Task, and Move to Background while it still holds up its turn (the CLI registers a foreground command as a task a few seconds in). A background task settling is a notice in the transcript, never the CLI's raw `<task-notification>` message.
- Progress indicators are transient. Every failed, unavailable, disconnected, or not-loaded path needs an explanatory state and a useful recovery action.
- Previews are part of the product-development workflow. Add representative `#Preview` coverage when adding or materially changing a view; seed samples through the real reducers where practical.

## Task tracking

Work is tracked in GitHub Issues on `AFRUITPIE/tether-app` (private), not in a
checked-in task file. Several agents work on this repository independently and
cannot see each other's transcripts, so the issue list is the shared state.

Use the `gh` CLI:

```sh
gh issue list                      # what is open
gh issue view <n>                  # the full description and discussion
gh issue comment <n> --body "..."  # claim it, or record a finding
gh issue close <n> --comment "..." # say what landed and how it was verified
```

Before starting, claim the issue with a comment so another agent does not
duplicate the work. Record anything you learn that changes the shape of the
task — a wrong assumption, a protocol detail, a rejected approach — as a
comment rather than only in a commit message; the next agent reads the issue,
not your transcript.

Reference the issue in the commit that addresses it (`Fixes #12`) so the log
and the tracker stay tied together. Open a new issue rather than expanding an
existing one when you find something unrelated in passing.

Issues labelled `verify` are changes that are written but not yet confirmed in
the running app. They usually cover motion or system behaviour that previews
cannot show, so they need `RunProject`, not `RenderPreview`.

Server-side work belongs to `AFRUITPIE/tether-server`; use `gh --repo` to file
it there when a change crosses the boundary.

## Commit messages

Commits carry no agent attribution: no `Co-Authored-By` trailer, no "generated
with" footer, no mention of the tool that wrote them. The author is always the
repository owner. Mentions of Claude Code as a product are fine and expected —
this app is a client for it.

## Generated code boundary

`TetherProtocol` is generated in the server repository. Never hand-edit:

```text
../tether-server/Sources/TetherProtocol/Generated.swift
../tether-server/schema/tether.schema.json
```

Change the Zod protocol definitions and implementation in `tether-server`, run `mise run gen` there, then update app call sites. Protocol unions deliberately preserve unknown future variants; keep forward-compatible fallbacks.

## Build and verification

Prepare the bundled server artifacts when server code or packaging changes:

```sh
cd ../tether-server
mise run compile -- --dev # into dist/ with a -dev stamp; the app's build phase runs this itself
mise run release          # tag, publish the binaries, and record the Agent SDK version
```

`TETHER_VERSION` comes from `package.json`, and the daemon replaces a running one only when that string differs. It is deliberately not the Agent SDK version: a server fix has to be able to ship without waiting for an SDK release. `AGENT_SDK_VERSION` is exported and reported separately.

Use Xcode 27 MCP as the primary app workflow. Open `Tether.xcodeproj`, then use the Xcode tools rather than raw `xcodebuild` or a separately launched LLDB session:

- `BuildProject` for app builds and diagnostics.
- `RenderPreview` for deterministic view verification and visual variants.
- `RunProject` with `attachDebugger: true` for the real app.
- `InvokeDebuggerCommand` and `GetConsoleOutput` for crashes, exceptions, and runtime warnings.
- Keep `TETHER_OPEN_THREAD=<id>` in the shared scheme when a repeatable launch target is needed, and disable it again before finishing unless the change is intentional.

Always look at the rendered or running UI after a UI change. A clean compile is not visual verification. Confirm that the inspected window belongs to the run you started; multiple stale Tether instances have previously caused false conclusions.

Package tests:

```sh
swift test --package-path TetherKit
```

The shared Xcode scheme also contains `TetherAppUITests`. Its launch sets
`TETHER_UI_TEST_MODE=1`, which uses an in-process JSON-RPC fixture and fails closed before any
daemon or SSH launch. The PR workflow runs it on `xcode-27` and resolves the public
SwiftPM protocol package without a repository secret.

`TetherPerformanceUITests` (in the same target) measures hitches with
`XCTHitchMetric` while it drives the inspector, its tabs, the sidebar, chat switching, a window
resize and a streamed reply, against the fixture's `performance` scenario: a 30-turn chat shaped
like real work, and a long working reply for each prompt. Run it with the Tether Performance scheme, which builds the tests in Release
(Apple: performance testing belongs in an optimized build; the main scheme skips the class, and CI
too), and read the hitch time ratio in the report. The fixture (`UITestFixture`,
`AppModel.uiTestFixture`) is compiled into every build for this, inert unless the app is launched
with `TETHER_UI_TEST_MODE=1`; Apple counts 10 ms/s or less as good. Keep in mind when reading
the numbers:

- The harness adds to them: every query or key press takes an accessibility snapshot of the whole
  app on its main thread, and accessibility stays on for the run. An interaction the app drives
  itself hitches about half as much.
- A live resize of an empty SwiftUI `NavigationSplitView` window already measures about 230 ms/s
  this way, so compare a resize with that, not with zero.
- The window is set to 1000×740 first; how much of the transcript wraps again depends on its width.
- The inspector's tabs live in the pane, not the toolbar: in the toolbar, any change of tab made
  AppKit re-tile the whole toolbar (about 50 ms/s more on this test), however the picker was hosted
  (a stack, a fixed size, item ids).
- Find elements with `element(boundBy: 0)`, not `firstMatch`, after the window's root `TabView`
  switches tabs: `firstMatch`'s shortcut through the tree then misses elements a whole query finds.
- `Self._logChanges()` in the view bodies, with `log stream --predicate 'category == "Changed Body
  Properties"'`, shows which views a test updates and why, where the SwiftUI instrument can't be
  used from the command line.

Live tests use a real Claude CLI session and can incur cost:

```sh
TETHER_E2E=1 swift test --package-path TetherKit
```

They run the server named by `TETHER_SERVER_BIN` in an isolated `TETHER_HOME`; to test a server working copy, set it to `bun run ../tether-server/src/cli.ts` (with bun's full path). They use Sonnet at low effort.

Do not run live/E2E tests unless their cost and external effects are warranted by the task. SSH end-to-end testing is currently deferred unless explicitly requested.

## Change discipline

- Read both repositories before changing a cross-boundary behavior.
- Preserve unrelated working-tree changes and Xcode user state.
- Keep changes small and coherent. Do not rewrite history, delete sessions, terminate user-owned app instances, or change host configuration without explicit direction.
- Update this guide when architecture or settled UI rules change.
