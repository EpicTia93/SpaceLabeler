# Space Labeler

A small macOS menu bar app that draws your own labels over Desktop thumbnails in Mission Control. It does not change Apple's “Desktop N” names. It uses the Dock's Accessibility tree to locate the thumbnails, then places click-through badges above them.

## Build and run

Requires macOS 14 or later and Xcode command line tools.

```sh
./build-app.sh
open dist/SpaceLabeler.app
```

Allow **Space Labeler** in **System Settings → Privacy & Security → Accessibility** when prompted. Open Mission Control and move the pointer to the top edge if the thumbnail strip is collapsed. The menu bar tag icon then lists the detected Desktops. Click one to set its label; leave the field empty to remove that label.

The menu also offers nine badge positions (corners, edges, and center), automatically varied colors, or one shared color chosen with the macOS color picker. Settings persist between launches. Unnamed Desktops have no badge.

## Current limits

- Labels are associated with a display's **Desktop number**. If you reorder Desktops or macOS renumbers them, edit the affected labels in the menu.
- Mission Control's Accessibility layout is not a documented API. A macOS update may require an adjustment to the thumbnail scanner.
- The overlays appear only when Mission Control exposes its expanded Desktop thumbnails. Full-screen app thumbnails are not labeled.
- The app needs Accessibility permission to read Dock's thumbnail positions. It does not use screen recording, inject code into Dock, or disable System Integrity Protection.
