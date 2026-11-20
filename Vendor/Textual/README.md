# Textual 0.5.0, patched

[Textual](https://github.com/gonzalezreal/textual) 0.5.0 (revision 01b5187), MIT License, Copyright (c) 2024 Guille Gonzalez.
Facienda shows agents' answers with it. The sources are upstream's unchanged except for one patch, marked
"Facienda patch" in `TextSelectionInteraction.swift` and `TextSelectionModel.swift`.

## The patch

Textual finds a clicked link, and the text to select, in the text layouts SwiftUI reports. Text put into a window
that is already on screen, as an opened task's answers are, is first reported with no lines. Its lines come while
SwiftUI draws, and SwiftUI then runs no change actions, so Textual kept the layouts without lines: no link in that
text opened and none of it could be selected. The patch also hands the layouts over on the next turn of the main
loop when they differ from the ones Textual holds.

Once upstream fixes this, point `project.yml` back at upstream and delete this folder.
