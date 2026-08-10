# Implementation notes

- The old icon used fine rings, depth, gradients, and shadows that lose clarity at small sizes.
- The selected direction is a filled leaf whose negative-space vein becomes a single clock hand.
- `Hourleaf/AppIcon.icon` is the canonical source. It contains one transparent monochrome SVG foreground layer; Icon Composer supplies the system-dark background, neutral shadow, translucency, masking, and appearance rendering.
- The legacy `AppIcon.appiconset` was removed after a clean build proved that `actool` compiled only `AppIcon.icon` and emitted the expected iPhone and iPad compatibility rasters.
- The user selected `#4A6DA7` as the interface accent. UI sites that previously hard-coded green now use the shared `AccentColor`; orange remains the independent credit/destructive-adjacent semantic color.
- For current iOS adaptation, `AppIcon.icon/Assets/HourleafLeaf.svg` preserves the mark as a transparent foreground layer with the clock vein cut out. No glass, highlight, corner mask, or platform tint is baked into the SVG.
