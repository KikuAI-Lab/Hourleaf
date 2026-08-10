# Evidence

## AC1 — PASS

`Hourleaf/AppIcon.icon/Assets/HourleafLeaf.svg` contains one text-free leaf silhouette with a single negative-space clock hand. The source contains no external clock ring, organization mark, raster gradient, baked shadow, or baked platform material.

## AC2 — PASS

The clean `actool` build emitted the expected Home Screen compatibility raster. Nick inspected the installed icon on the physical iPhone and accepted its legibility and appearance: "иконка классная".

## AC3 — PASS

`Hourleaf/AppIcon.icon` is the only app-icon source. Its Icon Composer document defines the monochrome SVG foreground, system-dark fill specializations, neutral shadow, and translucent material. The legacy `AppIcon.appiconset` is deleted.

## AC4 — PASS

A clean generic iOS device build completed with `BUILD SUCCEEDED`. The build log showed `actool` consuming `Hourleaf/AppIcon.icon` and `Hourleaf/Assets.xcassets`, with no legacy app-icon catalog.

## AC5 — PASS

The guarded installer verified a SHA-256 manifest for 20 regular files from the existing standard app container before building or installing. The signed local build then succeeded and updated `com.kikuai.hourleaf.local`. Nick completed the installed visual check.

## AC6 — PASS

`AccentColor.colorset` reads back as exact sRGB `0.290196, 0.427451, 0.654902`, or `#4A6DA7`. Former hard-coded service green sites now use `Color.accentColor`; credit remains `Color.orange`.

## AC7 — PASS

The clean build compiled the layered Icon Composer document. Default and dark use the system-dark fill, while the monochrome foreground and system-supplied material remain available for current iOS clear and tinted rendering without baked masking or glass effects.

Supporting command receipts are in `raw/verification-receipt.txt`.
