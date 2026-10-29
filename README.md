# MoltenVRKit

Put SwiftUI views from your Mac app into the [MoltenVR](https://moltenvr.com) VR shell.
Panels show up in the headset, and the user can click them with the laser, grab and move
them, and type into them with the VR keyboard.

```swift
import MoltenVRKit

let session = MVRShellSession(appName: "My App")
session.start()

session.presentPanel(id: "main", title: "My App",
                     pointSize: CGSize(width: 620, height: 420),
                     placement: MVRPanelPlacement(x: 0.6, y: 1.6, z: -1.4)) {
    MyPanelView()
}

session.showToast("Changes saved", duration: .seconds(3))
```

Add it with SwiftPM:

```swift
.package(url: "https://github.com/MoltenVR/MoltenVRKit", from: "1.0.0")
```

It needs macOS 14 and MoltenVR running on the same Mac. Your app can't be sandboxed,
because the kit talks to MoltenVR over a unix socket and shares IOSurfaces with it. If
Xcode says `No such module 'AppKit'`, it has picked an iOS simulator: choose My Mac.

## Notes

Your view lives in an invisible window that's captured at 2x and drawn in the headset.
Laser clicks, drags and scrolls are replayed as normal mouse events, so buttons, scroll
views and gestures just work. Hover is the exception, since `.onHover` only follows the
real cursor:

```swift
Button("Launch") { ... }
    .onLaserHover { hovering = $0 }
```

Clicking a `TextField` brings up the VR keyboard, and what the user types goes to that
field.

Placement is in meters with +y up and -z in front of the user. Height follows the aspect
of `pointSize`, and `curvature` wraps the panel onto a cylinder of that radius. When the
user moves a panel, `panel.onMoved` gives you the new placement to save.

The session reconnects by itself and re-sends its panels, so it doesn't matter whether
your app or MoltenVR starts first. Each app gets up to 4 panels.

`showToast(_:duration:)` displays a popup notification in the headset, replacing any
currently visible toast and restarting its timer. Toasts use one panel slot while visible;
call `dismissToast()` to close one early.

On macOS 14.4 and later capturing your own windows needs no permission. On 14.0 to 14.3
it needs Screen Recording: see `MVRScreenRecording`.

If you render with Metal you can skip the capture and hand over a global IOSurface with
`presentSurfacePanel`. You get the raw laser events, and resizing means creating a new
surface and calling `panel.update(placement:)`.

## Examples

`Examples/KitDemo` is the smallest useful app: a counter, a hover effect and a text field.
`Examples/MusicController` controls Apple Music from the headset through `osascript`.

```sh
cd Examples/MusicController && swift run
```

The protocol is in `Sources/MoltenVRKit/Internal/KitWire.swift` if you want to talk to
MoltenVR from something other than Swift.

## License

Apache 2.0. Apps that ship the kit need to include the text of `NOTICE` somewhere, such as
an acknowledgements file in the bundle.
