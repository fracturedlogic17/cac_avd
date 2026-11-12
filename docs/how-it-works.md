# How it works

[← Back to README](../README.md)

## What it does

`cac_setup.sh` handles the usual manual steps for getting a CAC working on Linux, and it's safe to run more than once.

| Step | What happens |
|---|---|
| **Detection** | Reads `/etc/os-release` and the CPU type, and refuses unsupported systems before changing anything. Finds which browsers your user has installed (native, Snap or Flatpak) and which of them an earlier run already set up. |
| **Your choices** | You choose *CAC only*, *CAC + Army AVD* or *Army AVD only* (the launcher plus the smart card and certificate setup its sign-in needs, no browsers), and which browsers to set up (ones already set up start unticked, so a re-run adds just new browsers). Then you confirm a summary. |
| **Dependencies** | Installs every package the chosen setup needs in one step, then checks that each required tool is present. For AVD, it also checks that FreeRDP was built with Azure AD support. It stops before configuring anything if something is missing. |
| **Smart card middleware** | Installs `pcsc-lite`/`pcscd`, the CCID reader driver, OpenSC, p11-kit and the NSS tools. Finds your card reader, checks it against the CCID driver's list of supported readers, and installs ACS's own driver for older ACS readers that need it. Starts `pcscd` and checks for a reader and a card (neither is required to finish setup). |
| **DoD certificates** | Downloads the official DISA PKI bundle and checks its signature against **pinned DoD Root CA 3–6 fingerprints**, then checks its SHA-256 hash. It installs the roots into the system trust store and both roots and intermediates into your browsers. Nothing is installed if a check fails. |
| **Firefox** | Writes an enterprise policy that installs the DoD roots and loads the CAC module for every profile, including ones created later. On Fedora it uses the system's `p11-kit-proxy` instead of loading OpenSC a second time. |
| **Flatpak browsers** | Flatpak sandboxes have no OpenSC, so the script adds a small socket-activated PKCS#11 bridge (`p11-kit-remote`) on the host. Each browser's sandbox is connected to it through its own adjusted copy of a p11-kit client, the DoD certificates go into that browser's own certificate store, and a self-test runs inside each sandbox. |
| **Chromium snap** | Connects the snap to `pcscd`, fixes a missing pcsc-lite file in the snap, and sets up its certificate store with the DoD certificates and the snap's own OpenSC. |
| **Army AVD launcher** | Installs **Army AVD**, a desktop app that lists the desktops and apps assigned to you in the Azure Government AVD feed and connects with **FreeRDP 3**. CAC sign-ins happen in a built-in sign-in window. |

## What gets changed on your system

**System-wide (root):**

| Path | Purpose |
|---|---|
| Packages | Smart card middleware and NSS tools; FreeRDP 3 and PyQt6 WebEngine only with AVD |
| `/usr/local/share/dod-pki/` | Extracted DoD roots, intermediates and extra site intermediates |
| `/etc/pki/ca-trust/source/anchors/DoD_*.pem` (Fedora) or `/usr/local/share/ca-certificates/dod/` (Ubuntu) | DoD roots in the system trust store |
| `/etc/firefox/policies/policies.json` | Firefox policy (other settings already in this file are kept) |
| `/etc/apt/sources.list.d/debian-backports.sources` | Debian only, with Army AVD, when backports weren't enabled: Debian's backports source, for a newer FreeRDP |
| `/etc/polkit-1/rules.d/90-cac-pcsc.rules` | Lets your user reach the card reader from outside the active desktop session (only written when a Flatpak browser is chosen, because the bridge needs it) |
| `/etc/systemd/user/cac-p11-bridge.socket`, `cac-p11-bridge@.service` | The PKCS#11 bridge for Flatpak browsers |

**For your user:**

| Path | Purpose |
|---|---|
| Firefox profiles, `~/.pki/nssdb` | DoD certificates (and the OpenSC module where p11-kit-proxy isn't used). `~/.pki/nssdb` is set up for native Chrome-family browsers and for the AVD sign-in window |
| `~/.var/app/<app-id>/cac-launch.sh` | Per-browser wrapper that connects a Flatpak browser to the bridge |
| `~/snap/chromium/<revision>/.pki/nssdb`, `~/snap/chromium/common/libpcsclite_real.so.1`, `~/.local/share/applications/chromium_chromium.desktop`, `~/.config/environment.d/90-cac-pcsclite.conf` | Chromium snap: its certificate store, the pcsc-lite client it's pointed at, and the menu entry and session setting that point it there |
| `~/.var/app/<app-id>/cac-p11-client.so` | An adjusted copy of a p11-kit client (your system's on Debian/Ubuntu, the browser runtime's on Fedora) that the Flatpak browser uses to reach the bridge |
| `~/.var/app/<app-id>/.pki/nssdb` or Firefox profiles under `~/.var/app/<app-id>/` | The Flatpak browser's certificate store (Firefox-based ones also get a `CAC (bridge)` security device) |
| `~/.local/share/applications/<app-id>.desktop` | Menu entry that starts the Flatpak browser through the wrapper |
| Flatpak overrides (`flatpak override --user --show <app-id>`) | Access to the bridge socket (`xdg-run/cac-p11`), and `--persist=.pki` for Chromium-based apps without home-folder access |
| `~/.local/bin/army-avd-qt`, `~/.local/bin/army-avd-gui` | The Army AVD tool and launcher |
| `~/.local/share/applications/army-avd-gui.desktop`, desktop shortcut, icon | The Army AVD launcher entries |
| `~/.config/army-avd-qt/`, `~/.local/share/army-avd-qt/` | Saved sign-in (refresh token, mode 0600), resource list, connection files, sign-in cookies |

## Security notes

- **Certificate trust:** the DoD bundle is installed only if its signed manifest chains to one of four DoD Root CA fingerprints written into the script, and the bundle's SHA-256 hash matches. Extra intermediates are added only if they chain to a root already in the system trust store.
- **Sign-in:** Army AVD uses the standard OAuth 2.0 authorization-code flow with PKCE against Microsoft's sign-in service for Azure Government. It sends access tokens only to `*.azure.us` and Microsoft sign-in hosts over HTTPS. The FreeRDP arguments, which include a token, go through an environment variable rather than the command line, so the token doesn't appear in `ps`.
- **Stored data:** the refresh token and account name are saved in `~/.config/army-avd-qt/` with mode 0600. `army-avd-qt logout` or *Clear sign-in…* deletes them, along with the sign-in window's cookies and cache.
- **Your PIN** is entered in the sign-in window and passed directly to NSS. It is never saved.
- **Card reader access:** the polkit rule lets processes running as your user use the card reader even outside the active desktop session, for example over SSH. The PIN is still required for every use.

Please report security issues privately rather than in a public issue.
