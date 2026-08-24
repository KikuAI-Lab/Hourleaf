# Direct Siri execution failure

The card-name repair proved discovery but exposed a second, independent
failure. After Siri reached the owner-created Shortcut, the owner reported the
system response `Что-то пошло не так`. A manual run of the same installed
Hourleaf action through iPhone Mirroring stopped even earlier with
`Это действие не разрешено`, before the duration prompt appeared.

Read-only inspection ruled out the visible configuration:

- the cards are named exactly `Запиши служение` and `Запиши кредит`;
- the service card still points to Hourleaf's `RecordTimeIntent`;
- duration is configured as `Ask Each Time` and no date is preset;
- the Shortcut privacy page allows Hourleaf access and execution while locked.

The remaining pre-parameter boundary was Hourleaf's explicit
`.requiresAuthentication` policy. Recording exposes no ledger contents, and
the store remains protected until the first device unlock, so service and
credit recording now use `.alwaysAllowed` on both iPhone and Apple Watch.
Validation, fixed entry kind, persistence, and the no-open-app behavior remain
unchanged.

# Remaining physical gate

The installed Store build still contains the former authentication policy. A
separate disposable build must first reach the duration prompt on the physical
iPhone without saving an entry. Only a later owner-approved Store upload can
put the same fix into the production Hourleaf binary.
