# macOS UI revamp

The working branch descends from PR #69’s repaired head (`5391f95`). It keeps native transcript anchoring and bounded eager layout. This work adds no scroll glide or resize-driven scroll commands.

## Design basis

Apple’s [Liquid Glass overview](https://developer.apple.com/documentation/technologyoverviews/liquid-glass), [app design overview](https://developer.apple.com/documentation/technologyoverviews/app-design-and-ui), and HIG guidance on [materials](https://developer.apple.com/design/human-interface-guidelines/materials), [buttons](https://developer.apple.com/design/human-interface-guidelines/buttons), [text fields](https://developer.apple.com/design/human-interface-guidelines/text-fields), [disclosure controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls), [motion](https://developer.apple.com/design/human-interface-guidelines/motion), and [accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) informed the changes. Claude’s desktop interface was inspected as a reference for compact tool summaries and independent editing/action controls.

The adversarial review challenged permanent glass bubbles, dominant message buttons, completion lists with no pointer path to later choices, cross-window animation ownership, and historical rows participating in matched geometry. Those concerns changed the implementation.

## Result

- Code uses primary text, a stronger semantic fill, and a border that strengthens with Increased Contrast. Selection, wrapping, horizontal scrolling, and cached measurement remain intact.
- The composer is a standard multiline rounded-border field beside a full labeled glass Send/Stop button. Existing draft persistence, attachments, input methods, and Shift-Return handling remain in place.
- Completion choices stay above the field inside the window, with bounded pages and pointer/keyboard controls. Commands use a terminal glyph.
- Suggestions have explicit capsule borders. Glass remains on controls and the brief sending handoff, rather than settled transcript content.
- Message actions live below the text: a labeled Copy and a regular More menu with Fork and Restore. They no longer float over selection.
- Tool summaries are compact. Leading disclosure triangles reveal labeled input/output sections; expanded groups offer Expand All/Collapse All and separate calls with dividers.
- Decorative symbols are faster and respect Reduce Motion and reduced effects.
- A send is identified by the actual TurnStart message ID and sending window, with a once-only claim. New Chat’s initial input is restricted to its first human prompt because ThreadStart does not return a message ID. A streaming update cannot cancel the claimed handoff. Historical rows never take part in its shared geometry.

## Validation

The Swift package suite passes 179 tests, including ID matching, competing clients/windows, duplicate echoes, failed/superseded sends, and new-chat ordering. UI checks cover Copy, Fork, Restore confirmation, attachments, Send availability, Return/Command-Return/Shift-Return, draft preservation, suggested tasks, compact/expanded tools, scripted existing/new chat sends, and resize/inspector bottom-follow behavior.

Code blocks were rendered and inspected in light appearance and dark Increased Contrast. Expanded command/output sections and the complete chat/completion layout were inspected visually. Fixture runs are in-process and do not send Claude requests. Retained XCTest recordings of existing-chat and New Chat sends were inspected frame by frame. The existing-chat recording shows the new prompt moving from the composer toward its row while the historical prompt remains stationary. The four recorded checks (both sends, completion navigation, and Shift-Return) pass. Animation state tests establish ownership and continuity; the owner can assess the final feel in the running app.
