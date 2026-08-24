# Implementation notes

- The shipped iPhone action was titled `Записать время`, while the public guide
  instructed the owner to invoke a custom Shortcut named `Запиши служение`.
  Siri runs a user-created Shortcut by its exact card name, so the mismatch was
  sufficient to make the documented app-name-free phrase undiscoverable.
- The smallest forward fix aligns the service action title with the promoted
  Shortcut title in EN/RU/UK. The action identifier, parameters, persistence
  path, authentication policy, Core Data model, and bundle identifiers are
  unchanged.
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
- Running an authenticated action while iPhone Mirroring controlled the locked
  handset returned the system message `Это действие не разрешено`. This is not
  treated as evidence about an unlocked Siri invocation. The product keeps
  `.requiresAuthentication`; weakening the existing privacy contract was not
  justified.
- The public EN/RU/UK guide now explains the legacy action title, exact card
  names, and one-time run. Support no longer implies that an iPhone-created
  Shortcut is executable on Apple Watch; Watch users are directed to the native
  Hourleaf watch app.
- No test entry was saved and no Hourleaf ledger, app container, account,
  entitlement, dependency, or Store build was changed.

## Primary references

- https://support.apple.com/guide/shortcuts/run-shortcuts-with-siri-apd07c25bb38/ios
- https://support.apple.com/guide/shortcuts/run-shortcuts-from-apple-watch-apd5888b0858/ios
- https://developer.apple.com/documentation/appintents/intentauthenticationpolicy/requiresauthentication
