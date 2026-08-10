# Hourleaf adaptive icon v1

## Goal

Replace the current detailed green icon with a minimal, production-ready iPhone icon: a black system-material field, a white Hourleaf mark, and an Icon Composer source that adapts to default, dark, clear, and tinted appearances.

## Acceptance criteria

- AC1: The mark combines a leaf and time without text, an external clock ring, baked gradients or shadows, or organization branding.
- AC2: The icon remains legible at small Home Screen sizes and leaves safe optical padding for Apple's mask.
- AC3: `AppIcon.icon` is the only app-icon source and contains a layered monochrome mark with Icon Composer appearance specializations.
- AC4: Asset-catalog compilation and a no-sign generic iOS build succeed.
- AC5: The guarded physical-device update preserves the existing Hourleaf data before installing, and the installed Home Screen icon is read back visually.
- AC6: Hourleaf's application accent is `#4A6DA7`; former brand-green controls and service markers use the asset-backed accent while credit remains orange.
- AC7: The latest Xcode build uses an Icon Composer layered icon so iOS can render Liquid Glass, clear, dark, and tinted appearances without baked-in shadows or material effects.

## Constraints

- Preserve the installed standard app and its ledger.
- Do not add dependencies or hand-round the icon corners.
- Keep pure monochrome geometry as the source of truth.
- Retain the generated-image originals outside the repository.

## Non-goals

- App Store publication or paid Developer Program activation.
- A broader brand system or marketing artwork.

## Verification plan

1. Inspect image dimensions and pixel/color characteristics.
2. Compile the asset catalog through the Hourleaf target.
3. Run the existing release-readiness guard.
4. Use the guarded local-device installer in explicit no-App-Group mode.
5. Confirm preservation receipt and visually inspect the icon on the paired iPhone.
