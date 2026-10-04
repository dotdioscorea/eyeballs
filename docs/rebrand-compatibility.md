# Requota source rename

The GitHub repository, Xcode project, targets, Swift modules, source directories, schemes, build scripts, app links and documentation use Requota.

Existing Apple bundle identifiers, App Group, Keychain service, background task identifiers, widget kind identifiers and persisted data paths retain their original values. Changing these would create a different installed app or lose access to saved credentials, history and configured widgets.

New widget and notification links use `requota://`. The app also accepts the previous `eyeballs://` scheme so already-installed widgets and saved links continue to open the same accounts. Historical release hashes and tags continue to identify the original binaries.
