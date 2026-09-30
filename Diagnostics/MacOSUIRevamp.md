# macOS UI revamp

The working branch descends from PR #69’s repaired head (`4e4d2fa`). Its resize test moves a display-edge window inward using the native title bar before exercising its border. It keeps native transcript anchoring and bounded eager layout. This work adds no scroll glide or resize-driven scroll commands.

## Design basis

Apple’s [Liquid Glass overview](https://developer.apple.com/documentation/technologyoverviews/liquid-glass), [app design overview](https://developer.apple.com/documentation/technologyoverviews/app-design-and-ui), and HIG guidance on [materials](https://developer.apple.com/design/human-interface-guidelines/materials), [buttons](https://developer.apple.com/design/human-interface-guidelines/buttons), [text fields](https://developer.apple.com/design/human-interface-guidelines/text-fields), [disclosure controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls), [motion](https://developer.apple.com/design/human-interface-guidelines/motion), and [accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) informed the changes. Claude’s desktop interface was inspected as a reference for compact tool summaries and independent editing/action controls.

The adversarial review challenged permanent glass bubbles, dominant message buttons, completion lists with no pointer path to later choices, cross-window animation ownership, and historical rows participating in matched geometry. Those concerns changed the implementation.

## Result

- Code uses primary text, a stronger semantic fill, and a border that strengthens with Increased Contrast. Selection, wrapping, horizontal scrolling, and cached measurement remain intact.
- The composer is a plain native multiline field on a padded interactive glass surface, beside an extra-large labeled glass Send/Stop button. Existing draft persistence, attachments, input methods, and Shift-Return handling remain in place.
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

The rounded-border field was replaced after hands-on feedback. The editor remains the native multiline TextField, with interactive regular glass and comfortable padding. The separate labeled Send/Stop control uses the system’s extra-large size. Faster symbol animations are retained.

Apple’s [custom glass guidance](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views) and [matched geometry documentation](https://developer.apple.com/documentation/swiftui/view/matchedgeometryeffect(id:in:properties:anchor:issource:)) informed a second recording pass. Matching layout around captured glass produced a stationary surface or an invisible in-flight bubble even though functional tests passed. The final handoff instead uses SwiftUI visualEffect after an isolated glass render: the whole surface and text lift together over 0.32 seconds, with a small initial stretch and a restrained settle. The footer follows the landing, and the transient glass settles into the ordinary blue bubble fill. The final bubble’s layout is reserved throughout, keeping selectable text from rewrapping in flight and preserving native transcript anchoring. Only the active send has a glass container; the composer frame is observed only by that bubble.

Existing-chat and New Chat recordings show the glass and text traveling together while historical bubbles remain stationary. Light and dark composer previews were inspected. A wrapped-prompt UI regression additionally checks readable multiline text within the window after sending. Reduce Motion and reduced effects continue to skip the movement entirely.

The final lifecycle review separates preflight visibility from the stable send task key, so a consumed send recreated during the recent-send window remains visible. Historical bubbles skip visual-effect geometry entirely. Pointer selection begins after the brief handoff has settled, preventing the temporary glass subtree from discarding a mid-flight selection.

The wrapped-prompt recording also exposed an immediate fixture reply drawing over the moving glass. The active sending row is now raised above its sibling rows only for the handoff; cancellation, disappearance, and supersession clear that layer ownership.

Final focused verification passes eight distinct UI checks: existing and new chat sends, wrapped-prompt readability, pending-prompt draft preservation, Command-Return, Shift-Return, command completion navigation, and resize/inspector end-follow. The wrapped-prompt and repaired-resize checks were rerun after final layering changes and passed. Recordings were inspected in both appearances, including the long prompt crossing an immediate reply.

## Messages reference refinement

The owner’s Messages recording inspired the permanent blue/white prompt palette and a quicker, smaller settle. The active sending prompt bypasses the generic new-row opacity fade so the glass and its text stay coherent during the lift. It still uses the existing once-only send ownership and leaves historical rows stationary.

Apple’s HIG [color guidance](https://developer.apple.com/design/human-interface-guidelines/color) informed the use of dynamic system blue and four appearance/contrast preview checks. The blue is mixed modestly with black, with a stronger mix for Increased Contrast. Rendered settled-fill contrast against white text measures approximately 6.28:1 in light appearance, 4.62:1 in dark, 9.45:1 in light Increased Contrast, and 5.23:1 in dark Increased Contrast. These measurements cover the ordinary settled fill; moving glass varies with the content behind it.

The updated build passes existing-chat, New Chat, and wrapped-prompt send UI checks. Retained recordings show the blue glass lifting together with its text, stable line wrapping, stationary history, and an immediate reply remaining behind the active surface.
