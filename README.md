# Space Labeler

A small macOS menu bar app that draws your own labels over Desktop thumbnails in Mission Control. It does not change Apple's “Desktop N” names. It uses the Dock's Accessibility tree to locate the thumbnails, then places click-through badges above them.

## Build and run

Requires macOS 14 or later and Xcode command line tools.

```sh
./build-app.sh
open dist/SpaceLabeler.app
```

Allow **Space Labeler** in **System Settings → Privacy & Security → Accessibility** when prompted. Open Mission Control and move the pointer to the top edge if the thumbnail strip is collapsed. Press and hold a Desktop preview for about 0.7 seconds to edit its label. Leave the field empty to remove the label. Moving the pointer while holding cancels editing, so normal dragging still works.

The app opens Accessibility Settings only when you choose that menu item. If the menu says **Accessibility: denied to this build** even though Space Labeler is enabled in Settings, remove its old entry, add the freshly built `dist/SpaceLabeler.app`, and enable it. The local build uses an ad hoc signature, so macOS may treat a rebuilt executable as a different Accessibility client.

The menu also offers **Edit labels…** as a fallback, nine badge positions (corners, edges, and center), automatically varied colors, or one shared color chosen with the macOS color picker. Settings persist between launches. Unnamed Desktops have no badge.

The app icon comes from `assets/logo.png`; the menu bar icon comes from `assets/top-bar-logo.png`.

## Current limits

- Labels follow each Desktop's macOS Space UUID when Desktops are reordered or removed. Existing number-based labels migrate the first time the app sees the expanded strip after an update.
- Space UUIDs come from macOS's Spaces configuration, which is not a documented API. The app waits for the configuration and thumbnail counts to agree before drawing labels.
- Mission Control's Accessibility layout is not a documented API. A macOS update may require an adjustment to the thumbnail scanner.
- The overlays and press-and-hold editing work only when Mission Control exposes its expanded Desktop thumbnails. Full-screen app thumbnails are not labeled.
- The app needs Accessibility permission to read Dock's thumbnail positions. It does not use screen recording, inject code into Dock, or disable System Integrity Protection.
