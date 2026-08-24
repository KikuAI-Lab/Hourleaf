# Remaining physical gate

The implementation and setup repair are complete, but direct Siri execution is
still unverified. iPhone Mirroring controls a locked handset and returned
`Это действие не разрешено`; this cannot establish how Siri behaves when the
owner invokes the exact phrase on the unlocked physical iPhone.

The decisive check is intentionally non-destructive:

1. Unlock the iPhone.
2. Say `Siri, запиши служение` directly to the iPhone.
3. If Siri asks for a duration, cancel instead of supplying one.

Asking for the duration proves discovery without creating a ledger entry.
