# OptiPDF

iPad PDF reader and annotator (PDFKit + PencilKit) with pencil tools, translation and AI notes. Personal TestFlight build.

## Reading controls

- The bottom-right **Tam ekran / Çık** control remains visible; the adjacent menu also exposes tools and settings.
- With a hardware keyboard, Up/Down scroll by the selected step (40, 80 or 160 points). Page Up/Down and Space/Shift-Space move by 85% of the viewport. In page-turn mode they go to the previous/next page. Shortcuts do not intercept text entry, modal sheets or the notes panel.
- Selection actions sit in a bounded bottom toolbar rather than tracking the selected text on every scroll event.
- Saved Pencil drawings load per page, including unvisited pages during flattened export. Notes are indexed only when their panel opens, with a yield between pages; export and summary remain disabled until indexing finishes.

## Release verification

The workflow compiles for iOS Simulator before signing and uploading to personal TestFlight. This is not a physical iPad/Pencil test. Device acceptance requires opening the large PDF, selecting with Pencil, scrolling while the selection toolbar is visible, closing the selection, entering/exiting fullscreen, and using keyboard shortcuts. Also verify note editing/undo, existing drawings after reopening, and export of drawings on unvisited pages. Do not describe a compilation-only build as device-verified.
