# Implementation notes

- The shipped iPhone action was titled `Записать время`, while the public guide
  instructed the owner to invoke a custom Shortcut named `Запиши служение`.
  Siri runs a user-created Shortcut by its exact card name, so the mismatch was
  sufficient to make the documented app-name-free phrase undiscoverable.
- The first forward fix aligned the service action title with the promoted
  Shortcut title in EN/RU/UK. The action identifier, parameters, persistence
  path, Core Data model, and bundle identifiers remained unchanged.
- A regression test parses all three app localizations and requires
  `intent.record.title` to equal `intent.shortcut.add_service`.
- The built-in App Shortcut phrases continue to include the application name,
  as required by the compiled App Intents grammar. The short app-name-free
  phrase is supported by a user-created Shortcut whose card has that exact
  name.
- The iPhone Shortcut was renamed and its service action refreshed on the
  physical iPhone. Both cards now read exactly `Запиши служение` and
  `Запиши кредит`; the service action retains fixed kind `Служение`, asks for
  one duration, and does not contain a preset date.
- A direct owner test then reached the Shortcut but returned the generic Siri
  failure `Что-то пошло не так`. Running the same installed action while
  iPhone Mirroring controlled the handset returned `Это действие не разрешено`
  before parameter collection. The card's privacy controls already allowed
  Hourleaf and locked execution, isolating the explicit intent authentication
  policy as the next executable boundary.
- Service and credit recording now declare `.alwaysAllowed` in both the iPhone
  and Watch binaries. These actions only add a validated record; they never
  reveal notes, history, totals, or reports. `openAppWhenRun` stays false, Core
  Data retains complete-until-first-authentication file protection, and the
  normal command validation still rejects empty, invalid, or excessive time.
- Fresh compiled iPhone and Watch App Intents metadata emits authentication
  policy `0` for all four record actions, with the policy explicitly declared
  and background execution preserved.
- The public EN/RU/UK guide now explains the legacy action title, exact card
  names, and one-time run. Support no longer implies that an iPhone-created
  Shortcut is executable on Apple Watch; Watch users are directed to the native
  Hourleaf watch app.
- No test entry was saved and no Hourleaf ledger, production app container,
  account, entitlement, dependency, schema, or Store build was changed.

## Primary references

- https://support.apple.com/guide/shortcuts/run-shortcuts-with-siri-apd07c25bb38/ios
- https://support.apple.com/guide/shortcuts/run-shortcuts-from-apple-watch-apd5888b0858/ios
- https://developer.apple.com/documentation/appintents/intentauthenticationpolicy/requiresauthentication
- https://developer.apple.com/documentation/appintents/intentauthenticationpolicy/alwaysallowed
