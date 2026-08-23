# Implementation notes

- The interaction uses SwiftUI's native iOS 17 `sensoryFeedback(.selection)`
  instead of a UIKit generator, custom pattern, dependency, or permission.
- `TimeWheelPicker` keeps feedback disabled by default because it is shared by
  Add, history editing, and timer review. Only `QuickEntryView` opts into the
  preference, which preserves the frozen Add-screen scope.
- The feedback trigger changes only inside the Picker-facing binding setter.
  Parent updates bypass that setter, and identical values are ignored, so
  opening the screen and resetting the form after save request no feedback.
- The enabled-by-default preference is local `UserDefaults`/`@AppStorage`
  presentation state. It does not alter Core Data, ledger backups, reports,
  Watch state, permissions, or synchronization.
- Settings uses one native Toggle under Appearance with consequence-focused
  copy. The title avoids the technical term “haptics,” and the explanation is
  localized in English, Russian, and Ukrainian.
- The UI persistence test resets only this preference behind the existing
  `-uiTesting` boundary. iOS 26 exposes the switch as a full-row accessibility
  element, so the test taps the physical switch side deliberately, re-enters
  Settings, then proves both disabled and restored states after relaunch.
- Simulator verifies trigger policy, UI wiring, and persistence but cannot
  prove Taptic Engine feel. A physical feel check belongs to a later signed
  next-version build; no physical device is touched in this task.
- A pre-existing share-sheet UI test exposed an iOS 26.5 localization issue:
  the system close button was labelled in Russian even while Hourleaf launched
  in English. The two share-sheet tests now use Apple's accessibility
  identifier `header.closeButton` instead of localized text; both pass.
- Lazy-senior result: the native SwiftUI feedback primitive is the lowest
  honest rung. No custom haptic engine, dependency, wrapper, or GitHub prior-art
  search is justified for this platform-local interaction.
