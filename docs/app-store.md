# Publishing on the Mac App Store

The App Store edition is the same app built by `tool/build_appstore.sh`. The
store requires Apple's sandbox, so it differs from the direct download in a
few places:

| | Direct download (DMG) | App Store |
|---|---|---|
| SSH keys in `~/.ssh` | read directly | after one "Allow access" in Settings → This Mac |
| File browser, "This computer" | whole disk | starts in Downloads; other folders via *Choose a folder…* |
| Sync through a folder | yes | not offered (use your server or Google Drive) |
| Where vaults are kept | `~/Library/Application Support/dev.marsa.marsa` | the app's sandbox container |

The two editions do not see each other's vaults. To move, turn on sync in one
and use *Join a synced vault* in the other.

## One-time setup (Apple Developer account holder)

1. **Certificates.** Xcode → Settings → Accounts → your team → *Manage
   Certificates* → **+** → add **Apple Distribution** and **Mac Installer
   Distribution**.
2. **App ID.** <https://developer.apple.com/account/resources/identifiers/add/bundleId>
   → App IDs → App → platform macOS, description `Marsa`, explicit bundle ID
   `dev.marsa.marsa`. No capabilities need ticking.
3. **Provisioning profile.** <https://developer.apple.com/account/resources/profiles/add>
   → *Mac App Store Connect* → the App ID above → the Apple Distribution
   certificate → name it `Marsa App Store` → download the
   `.provisionprofile` file.
4. **App record.** <https://appstoreconnect.apple.com/apps> → **+** → New App
   → macOS, name `Marsa` (if taken, `Marsa SSH`), primary language English,
   the bundle ID above, SKU `marsa-mac`.

## Build and upload

```sh
tool/build_appstore.sh ~/Downloads/Marsa_App_Store.provisionprofile
```

It produces `dist/Marsa-appstore.pkg`. Upload it with the **Transporter** app
(drag the file in, press Deliver). After some minutes the build appears in
App Store Connect under the app's *TestFlight* tab and can be selected for
the version being submitted.

Each upload needs a higher build number: the part after `+` in `version:` in
`pubspec.yaml`.

## Store listing

**Subtitle:** SSH and SFTP with synced vaults

**Category:** Developer Tools

**Description:**

> Marsa is an open-source SSH and SFTP client. Your servers, keys and
> snippets live in a vault encrypted on your Mac with your master password,
> and the vault syncs across your devices through a server you own or your
> Google Drive. No subscription and no account with us.
>
> • Terminal sessions in tabs, or tiled side by side by dragging
> • SFTP between your Mac and a server, or directly from server to server
> • Jump hosts, and local, remote and dynamic (SOCKS) port forwarding
> • Sign in with the SSH keys already on your Mac, or keep keys in the vault
> • Snippets to run saved commands, known-hosts pinning, light and dark themes
> • Import from an OpenSSH config, a CSV, PuTTY or MobaXterm
>
> Sync is optional and off by default. When it is on, only the encrypted
> vault file leaves your Mac. The source code is public under the MIT
> license.

**Keywords:** ssh,sftp,terminal,server,vps,devops,sysadmin,shell,port forwarding,linux

**Support URL:** `https://github.com/AdnanBolifa/marsa/issues`
**Marketing URL:** `https://adnanbolifa.github.io/marsa/`
**Privacy Policy URL:** `https://adnanbolifa.github.io/marsa/privacy.html`

**Screenshots:** `docs/screenshots/*.png` are 1280×800, a size the Mac App
Store accepts. Good ones to use: `tiles-light`, `hosts-light`, `sftp-dark`,
`terminal-dark`, `sync-light`.

**App Privacy:** *Data Not Collected*.

**Notes for App Review** (they need a way to try an SSH client):

> Marsa is an SSH/SFTP client, so it needs a server to connect to. To try it:
> create a vault with any master password, press New host, and enter a test
> server. One is available at HOST with username USER and password PASS.
> The app requests access to user-selected folders so the user can browse
> local files for SFTP transfers and allow reading their own SSH keys.

Replace HOST/USER/PASS with a throwaway account on a server you do not mind
reviewers logging in to.

**Export compliance.** App Store Connect asks whether the app uses
encryption. It does: SSH, and AES-256 for the vault, implemented in the app
with standard, published algorithms. Answer those questions yourself, as the
publisher; Apple's help page explains which documentation each answer needs.
