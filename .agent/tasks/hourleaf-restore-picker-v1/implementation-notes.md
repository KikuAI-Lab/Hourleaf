# Implementation notes

Build 2 generated a dynamic undeclared type from the `.hourleafbackup` filename
extension. Apple documents that proprietary document formats need an exported
type declaration in the app Info.plist. The fix establishes one stable type
identifier instead of broadening the picker to all data files.

The focused UI reproduction then showed the more immediate presentation bug:
two consecutive `fileImporter` modifiers were attached to the same Form. The
second CSV importer remained effective while the first restore importer did not
present. One importer now carries an explicit restore-or-CSV operation and
dispatches its result to the existing independent handlers.
