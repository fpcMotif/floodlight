# Floodlight

Floodlight is a macOS launcher that finds apps, files and clipboard history from one panel.

## Language

**File Index**:
The record of every file and folder name under the home folder that file search reads. A fresh scan replaces the whole record; nothing edits it in place.
_Avoid_: flix, names file, index file

**Clipboard History**:
The record of what was copied, and the owner of the rules for what a copy becomes. It decides which copies to skip and classifies each entry once, when it records it.
_Avoid_: clipboard cache, pasteboard manager

**Clipboard Entry**:
One recorded copy: text, a file, or a picture. Its content (plain, link, colour, code or path) is decided when it is recorded and never changes.
_Avoid_: clip, item
