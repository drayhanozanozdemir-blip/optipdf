# OptiPDF

iPad PDF reader and annotator (PDFKit + PencilKit) with pencil tools, translation and AI notes. Personal TestFlight build.

## Reading controls

- The bottom-right **Tam ekran / Çık** control remains visible; the adjacent menu also exposes tools and settings.
- With a hardware keyboard, Up/Down scroll by the selected step (40, 80 or 160 points). Page Up/Down and Space/Shift-Space move by 85% of the viewport. In page-turn mode they go to the previous/next page. Shortcuts do not intercept text entry, modal sheets or the notes panel.
- Selection actions sit in a bounded bottom toolbar rather than tracking the selected text on every scroll event.
- Page scrubber: a slim scrubber on the right edge fades in while the page moves or a finger touches it and hides after 1.5 s; in fullscreen it shows only with the controls, and never while text is selected. Dragging its thumb (44 pt target, finger or pointer only; the Pencil keeps drawing, scrolling and gliding) jumps through the book with a bubble "S. 245 · Kapitel" taken from the PDF outline, which is read once off the main thread. It works in continuous, page-turn and two-page layouts.
- The page indicator shows "245 / 1514 · Kapitel". Tapping it opens "Sayfaya git": number field (Return jumps, out-of-range numbers are clamped, printed page labels are offered when the PDF has its own), the last 5 places, bookmarks and the "Sayfalar" organizer, which also stays in the menu.
- Jump history: outline, search result, bookmark, note, go to page, scrubber release, "Son konumlar" and internal links remember the exact place they left (page and scroll offset). A "‹ S. 123'e dön" capsule shows for 8 s after a jump and offers forward after going back; both are also in the menu. Browsing search results or re-adjusting the scrubber within a minute keeps the first place. Recent places are saved with the reading position; the back and forward stacks last for the session.
- Keyboard: ⌘[ back, ⌘] forward, ⌘L "Sayfaya git", under the same focus rules as scrolling.
- Saved Pencil drawings load per page, including unvisited pages during flattened export. Notes are indexed only when their panel opens, with a yield between pages; export and summary remain disabled until indexing finishes.

## Release verification

The workflow compiles for iOS Simulator before signing and uploading to personal TestFlight. This is not a physical iPad/Pencil test. Device acceptance requires opening the large PDF, selecting with Pencil, scrolling while the selection toolbar is visible, closing the selection, entering/exiting fullscreen, and using keyboard shortcuts. Also verify note editing/undo, existing drawings after reopening, and export of drawings on unvisited pages. Do not describe a compilation-only build as device-verified.

The optional one-off UI probe uses an isolated `READER_PROBE` build with a generated 1000-page document. It measures settled PDF offsets and key-handler invocation counts, not just the displayed page number. In diagnostic run 35149129972, XCTest PageDown delivered no application key event; Down Arrow moved 80 points and Space moved 85% of the viewport through the reader handler. Page Up/Down therefore remain physical-keyboard acceptance checks, not simulator-verified features. The release probe covers Up/Down and Space/Shift-Space alongside selection, scrolling and fullscreen controls. Probe-only instrumentation is excluded from the signed release; the generated document does not validate Files import or autosave of the user's large PDF.
