# macOS UI revamp

The working branch descends from PR #69’s repaired head (`4e4d2fa`). Its resize test moves a display-edge window inward using the native title bar before exercising its border. It keeps native transcript anchoring and bounded eager layout. This work adds no scroll glide or resize-driven scroll commands.

## Design basis

Apple’s [Liquid Glass overview](https://developer.apple.com/documentation/technologyoverviews/liquid-glass), [app design overview](https://developer.apple.com/documentation/technologyoverviews/app-design-and-ui), and HIG guidance on [materials](https://developer.apple.com/design/human-interface-guidelines/materials), [buttons](https://developer.apple.com/design/human-interface-guidelines/buttons), [text fields](https://developer.apple.com/design/human-interface-guidelines/text-fields), [disclosure controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls), [motion](https://developer.apple.com/design/human-interface-guidelines/motion), and [accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) informed the changes. Claude’s desktop interface was inspected as a reference for compact tool summaries and independent editing/action controls.

The adversarial review challenged permanent glass bubbles, dominant message buttons, completion lists with no pointer path to later choices, cross-window animation ownership, and historical rows participating in matched geometry. Those concerns changed the implementation.

## Result

- Code uses primary text, a stronger semantic fill, and a border that strengthens with Increased Contrast. Selection, wrapping, horizontal scrolling, and cached measurement remain intact.
- The composer is a plain native multiline field on a padded interactive glass surface, between circular icon-only Add and Send/Stop controls. Their shared diameter comes from the one-line editor’s intrinsic height. Existing draft persistence, attachments, input methods, and Shift-Return handling remain in place.
- Completion choices stay above the field inside the window, with bounded pages and pointer/keyboard controls. Commands use a terminal glyph.
- Suggestions have explicit capsule borders. Glass remains on controls and the brief sending handoff. Settled human prompts use ordinary system-blue fills and white text; synthetic messages retain their secondary styling.
- Message actions live below the text: a labeled Copy and a regular More menu with Fork and Restore. They no longer float over selection.
- Tool summaries are compact. Leading disclosure triangles reveal labeled input/output sections; expanded groups offer Expand All/Collapse All and separate calls with dividers.
- Decorative symbols are faster and respect Reduce Motion and reduced effects.
- A send is identified by the actual TurnStart message ID and sending window, with a once-only claim. New Chat’s initial input is restricted to its first human prompt because ThreadStart does not return a message ID. A streaming update cannot cancel the claimed handoff. Historical rows never read the send geometry or create glass renderers.

## Validation

The Swift package suite passes 179 tests, including ID matching, competing clients/windows, duplicate echoes, failed/superseded sends, and new-chat ordering. UI checks cover Copy, Fork, Restore confirmation, attachments, Send availability, Return/Command-Return/Shift-Return, draft preservation, suggested tasks, compact/expanded tools, scripted existing/new chat sends, and resize/inspector bottom-follow behavior.

Code blocks were rendered and inspected in light appearance and dark Increased Contrast. Expanded command/output sections and the complete chat/completion layout were inspected visually. Fixture runs are in-process and do not send Claude requests. Retained XCTest recordings of existing-chat and New Chat sends were inspected frame by frame. The existing-chat recording shows the new prompt moving from the composer toward its row while the historical prompt remains stationary. The recorded sends pass; completion navigation and Shift-Return also pass. Animation state tests establish ownership and continuity; the owner can assess the final feel in the running app.

## Glass composer and send refinement

The rounded-border field was replaced after hands-on feedback. The editor remains the native multiline TextField, with interactive regular glass and comfortable padding. The separate Send/Stop control is now icon-only and circular. A native SwiftUI Layout uses a hidden text probe with the same font and padding to match both controls to the one-line field, including larger text. Multiline drafts grow above the bottom-aligned circles. Faster symbol animations are retained.

Apple’s [custom glass guidance](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views) and [matched geometry documentation](https://developer.apple.com/documentation/swiftui/view/matchedgeometryeffect(id:in:properties:anchor:issource:)) informed the recording checks. Matching layout around captured glass produced a stationary surface or an invisible in-flight bubble even though functional tests passed. The handoff instead uses SwiftUI visualEffect to move the rendered message with a damped spring. Only its background enters an isolated glass container; text stays outside that capture so an independently morphing surface cannot obscure it. The background changes size without stretching its corners or remeasuring the message’s text. Native `.materialize` removes the glass while ordinary blue fills in during travel. The final bubble’s layout stays reserved throughout, preserving native transcript anchoring. Only the active send has a glass container; its source frame is captured before the draft clears.

Existing-chat and New Chat recordings show the glass and text traveling together while historical bubbles remain stationary. Light and dark composer previews were inspected. A wrapped-prompt UI regression additionally checks readable multiline text within the window after sending. Reduce Motion and reduced effects continue to skip the movement entirely.

The final lifecycle review separates preflight visibility from the stable send task key, so a consumed send recreated during the recent-send window remains visible. Historical bubbles skip visual-effect geometry entirely. Pointer selection begins after the brief handoff has settled, preventing the temporary glass subtree from discarding a mid-flight selection.

The wrapped-prompt recording also exposed an immediate fixture reply drawing over the moving glass. The active sending row is now raised above its sibling rows only for the handoff; cancellation, disappearance, and supersession clear that layer ownership.

Final focused verification passes eight distinct UI checks: existing and new chat sends, wrapped-prompt readability, pending-prompt draft preservation, Command-Return, Shift-Return, command completion navigation, and resize/inspector end-follow. The wrapped-prompt and repaired-resize checks were rerun after final layering changes and passed. Recordings were inspected in both appearances, including the long prompt crossing an immediate reply.

## Messages reference refinement

The owner’s Messages recording inspired the permanent blue/white prompt palette. A complete frame-by-frame pass located the flight at approximately 6.4–7.15 seconds: the surface starts at the editor’s width, narrows as it accelerates upward, overshoots its settled top edge by roughly 34 pixels (about 3.6% of its travel), and returns softly. The spring uses response 0.52 and damping fraction 0.74, with a faster, more damped spring for the background’s size. Animation completion drives cleanup instead of a fixed landing timer. The active sending prompt bypasses the generic new-row opacity fade. Once-only ownership keeps historical rows stationary.

Apple’s HIG [color guidance](https://developer.apple.com/design/human-interface-guidelines/color) informed the use of dynamic system blue and four appearance/contrast preview checks. The blue is mixed modestly with black, with a stronger mix for Increased Contrast. Rendered settled-fill contrast against white text measures approximately 6.28:1 in light appearance, 4.62:1 in dark, 9.45:1 in light Increased Contrast, and 5.23:1 in dark Increased Contrast. These measurements cover the ordinary settled fill; moving glass varies with the content behind it.

Focused UI checks pass for existing-chat, New Chat, and wrapped-prompt sends, Send availability, and the native Add menu/file panel. Regression assertions verify matching circular action hit areas and that a sent message’s footer becomes usable when the spring completes. Previews cover Stop, multiline drafts, and larger text. Retained recordings show the narrowing surface, visible text, stable line wrapping, stationary history, native glass dissolution, and an immediate reply behind the active surface. The multiline source is captured before clearing the draft so its initial background has the filled editor’s height.

## Coordinated transcript lift and single surface

Hands-on feedback exposed a visible duplicate during the glass-to-blue crossfade: native glass removal retained an outgoing surface while the blue background resized. The send now has one blue-filled glass surface for its entire spring, with no separately disappearing sibling. Its shape still narrows with the faster size spring and its selectable text keeps its final layout. The settled bubble remains an ordinary fill.

The transcript now makes room with the same response-0.52, damping-0.74 spring as the bubble. The first version held the scroll position and switched the size-change anchor during a send, then scrolled to the bottom; recorded frame by frame, the rest of the transcript still jumped in one frame. Two causes: the echo's insertion carried no animation, and starting a turn moved the settled tail's rows into the lazy stack, whose guessed heights shrank the content by ~660 pt for a frame (the anchor then swung back). Now `.animation(_:value:)` on the scroll view for `arrivedPrompt` and `isThinking` makes the native bottom anchor's adjustment spring (measured: 157 pt over ~400 ms with a sub-point settle, no first-frame step), and the split stays put until the turn's prompt is in. The anchor switching, `scrollTo`, preparation tokens and window-owner claim are gone.

Retained short-send and full-transcript recordings show one resizing bubble and the transcript’s upward lift with a small return. Existing-chat, multiline, New Chat, full-transcript landing, and resize/inspector anchoring checks pass across the focused runs. Three package checks cover overlapping sends, stale completion, and the filled composer’s captured shape. Resize automation now leaves enough space for the first expansion on smaller local windows and corrects native edge snapping before asserting the exact viewport. These recordings verify the visual sequence; they do not measure render-loop hitch rate.
