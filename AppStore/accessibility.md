# Accessibility information for Hourleaf 1.0

Hourleaf's release candidate has automated coverage for the following App
Store accessibility features:

- **VoiceOver:** critical controls expose localized accessibility labels.
- **Larger Text:** onboarding and Data Management remain reachable at
  Accessibility XXXL.
- **Dark Interface:** critical Add, History, Progress, and Settings surfaces
  remain usable in dark appearance.
- **Reduce Motion:** the manual-entry and timer-review flows remain usable with
  Reduce Motion enabled.

Select only these four features in App Store Connect for version 1.0. Do not
claim Voice Control, Sufficient Contrast, Differentiate Without Color, closed
captions, or audio descriptions until their respective Apple criteria receive
a dedicated acceptance pass.

Before submission, repeat a short physical-device VoiceOver and Accessibility
XXXL smoke on the signed distribution build. Automated simulator evidence is
necessary release coverage but is not a substitute for that owner acceptance.
