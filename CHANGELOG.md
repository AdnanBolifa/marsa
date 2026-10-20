# Changelog

## 0.5.0

### Device keys
- Every computer now signs in with its own SSH key. The private key stays
  in that computer's Keychain or Credential Manager; only the public key
  syncs with the vault.
- Setting up a new device no longer means copying keys around: join the
  vault, then approve the new device on one that already has access. Marsa
  adds its key to every server in the vault, in the background and over
  any connection you open, and retries servers it cannot reach.
- Settings → Devices lists every device with its key fingerprint and how
  many servers have its key. Removing a device takes its key off every
  server.
- New hosts sign in with "this device's own key" by default; if a server
  asks for a password the first time, type it once and the keys are added.
- A device waiting for approval says so when a server turns it away.

## 0.4.2

### Terminal
- Copy selected text with Ctrl+C, as in Windows Terminal: with text selected
  it copies, with nothing selected it still sends Ctrl+C to the server.
  Ctrl+Shift+C always copies, Cmd+C on a Mac. Selecting by dragging is now
  covered by a test, including while a program such as tmux or vim has
  mouse reporting on.
- Press Enter on an ended or failed session to reconnect, no mouse needed.
  The terminal and the bar under it say so.

### Tabs
- The **+** button in the tab strip opens the Hosts page instead of a
  drop-down menu.

### SFTP
- A single click ticks a folder; a double click opens it.
- Drag and drop files and folders: onto the other pane to copy them into the
  folder it shows, onto a folder in the other pane to copy into that folder,
  or onto a folder in the same pane to move them into it. Dragging a ticked
  item takes everything ticked along.
- Fixed: a slow folder listing that finished after a newer one could take a
  pane back to the folder it had just left.

### Sync
- Fixed: cancelling a Dropbox or Google Drive sign-in and trying again
  straight away could wrongly report that the sign-in port was in use, and
  cancelling while the port was still opening left it open.
