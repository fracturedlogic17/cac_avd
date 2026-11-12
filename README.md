<p align="center">
  <img src="assets/army-avd.svg" width="96" alt="Army AVD icon">
</p>

<h1 align="center">CAC on Linux</h1>

<p align="center">
  One script to set up a DoD Common Access Card (CAC) on Linux for your browsers
  (<b>Firefox, Chrome, Edge, Brave and more</b>: native, Snap or <b>Flatpak</b>)
  and <b>Army Azure Virtual Desktop (AVD)</b>.
</p>

<p align="center">
  <img alt="Fedora: tested" src="https://img.shields.io/badge/Fedora-tested-51A2DA?logo=fedora&logoColor=white">
  <img alt="Ubuntu 24.04 and 26.04: tested" src="https://img.shields.io/badge/Ubuntu%2024.04%20%7C%2026.04-tested-E95420?logo=ubuntu&logoColor=white">
  <img alt="Debian 13: tested" src="https://img.shields.io/badge/Debian%2013-tested-A81D33?logo=debian&logoColor=white">
  <img alt="Linux Mint 22: tested" src="https://img.shields.io/badge/Linux%20Mint%2022-tested-87CF3E?logo=linuxmint&logoColor=white">
  <img alt="Shell: Bash" src="https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue"></a>
</p>

---

```bash
git clone https://github.com/fracturedlogic17/cac_avd.git
cd cac_avd
sudo ./cac_setup.sh
```

The script detects your distribution and installed browsers. It then asks whether you want **CAC only** or **CAC + Army AVD**, and lets you tick which browsers to set up (arrow keys and Space). It shows a summary and changes nothing until you confirm.

## Contents

- [What it does](#what-it-does)
- [Supported systems](#supported-systems)
- [Requirements](#requirements)
- [Install](#install)
- [Using it](#using-it)
- [Army AVD launcher](#army-avd-launcher)
- [What gets changed on your system](#what-gets-changed-on-your-system)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [Security notes](#security-notes)
- [Disclaimer](#disclaimer)
- [License](#license)

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

## Supported systems

| Distribution | Status |
|---|---|
| **Fedora** (Workstation / KDE, recent releases) | ✅ Developed and tested here: Fedora 45, FreeRDP 3.33. CAC sign-in tested in Firefox, Google Chrome, and the Ungoogled Chromium, Vivaldi and LibreWolf Flatpaks, plus Army AVD. |
| **Ubuntu 24.04 LTS** | ✅ Tested: CAC sign-in in Firefox (snap and Mozilla's `.deb`), Google Chrome, the Chromium snap, and the Ungoogled Chromium, Brave, Vivaldi and Firefox Flatpaks, plus Army AVD. ❌ The LibreWolf Flatpak doesn't work. Ubuntu has a few differences (see below). |
| **Ubuntu 26.04 LTS** | ✅ Tested: CAC sign-in in Firefox (snap and Mozilla's `.deb`), Google Chrome, the Chromium snap, and the Ungoogled Chromium, Brave, Vivaldi, Firefox and LibreWolf Flatpaks, plus Army AVD. 26.04 runs `pcscd` as its own user; the script makes sure it may open your reader. |
| **Debian 13** (trixie) | ✅ Tested: CAC sign-in in Firefox ESR (Debian's default) and Mozilla's Firefox, Debian's Chromium, Google Chrome, and the Ungoogled Chromium and Firefox Flatpaks, plus Army AVD. Army AVD needs a newer FreeRDP than Debian ships (3.15 lacks the Azure Government options), so the script installs FreeRDP from Debian's backports, adding the backports source if needed. |
| **Linux Mint 22** (Cinnamon) | ✅ Tested: CAC sign-in in Mint's Firefox, Google Chrome, Mint's Chromium and Vivaldi (native packages), and the Ungoogled Chromium, Brave and Firefox Flatpaks, plus Army AVD. ❌ The LibreWolf Flatpak doesn't work (as on Ubuntu 24.04). Mint has no snaps. |
| **Newer Ubuntu releases** | ⚠️ Should work, but **not yet tested**. The menu marks snaps and Flatpaks *untested*. |
| **Ubuntu 22.04** | ❌ The Army AVD launcher won't install, because there's no FreeRDP 3 or PyQt6 WebEngine package. The browser steps may still work. |
| Other Fedora- or Debian/Ubuntu-based distributions (RHEL, Pop!_OS, Zorin…), older Debian or Mint | Untested. The script warns and asks before continuing; use `--force` when running without a terminal. |
| Older Fedora/Ubuntu/Debian/Mint, non-x86_64 CPUs | Refused unless you confirm (or pass `--force`). |
| Anything else (Arch, openSUSE…) | Refused. The script needs `dnf` or `apt-get`. |

### Browsers

| Browser | Fedora | Ubuntu 24.04 | Ubuntu 26.04 | Debian 13 | Mint 22 | How |
|---|---|---|---|---|---|---|
| Firefox (native package; on Ubuntu, Mozilla's `.deb`; on Debian, Firefox ESR too; on Mint, Mint's own) | ✅ | ✅ | ✅ | ✅ | ✅ | Enterprise policy + profile certificates |
| Firefox (Snap, Ubuntu's default) | — | ✅ | ✅ | — | — | Same policy, plus `snap connect firefox:pcscd` |
| Google Chrome, Chromium, Microsoft Edge, Brave, Vivaldi (native packages) | ✅ | ✅ | ✅ | ✅ | ✅ | They share `~/.pki/nssdb`, so they appear as **one** choice (tested with Google Chrome, Debian's and Mint's Chromium, and Vivaldi) |
| **Chromium-based Flatpaks:** Ungoogled Chromium; Chromium, Google Chrome, Microsoft Edge, Brave, Vivaldi, Opera | ✅ Ungoogled Chromium, Vivaldi<br>⚠️ others untested | ✅ Ungoogled Chromium, Brave, Vivaldi<br>⚠️ others untested | ✅ Ungoogled Chromium, Brave, Vivaldi<br>⚠️ others untested | ✅ Ungoogled Chromium<br>⚠️ others untested | ✅ Ungoogled Chromium, Brave<br>⚠️ others untested | PKCS#11 bridge to the card; certificates go into the app's `~/.pki/nssdb` |
| **Firefox-based Flatpaks:** Firefox, LibreWolf, Waterfox, Zen, Floorp | ✅ LibreWolf<br>⚠️ others untested | ✅ Firefox<br>❌ LibreWolf<br>⚠️ others untested | ✅ Firefox, LibreWolf<br>⚠️ others untested | ✅ Firefox<br>⚠️ others untested | ✅ Firefox<br>❌ LibreWolf<br>⚠️ others untested | PKCS#11 bridge added to each profile as a security device; certificates go into each profile |
| Chromium **Snap** | — | ✅ | ✅ | — | — | `snap connect chromium:pcscd`, the snap's own OpenSC, plus a fix for a missing pcsc-lite file in the snap (see below) |

**LibreWolf Flatpak:** works on Fedora and Ubuntu 26.04, but CAC sign-in doesn't work on Ubuntu 24.04 or Linux Mint 22 (which is built on Ubuntu 24.04). The cause isn't known yet; something those two share is likely involved. The menu lists it there unticked as not working; you can still tick it to try.

The script shows the same status next to each browser when it asks which ones to set up. It also checks which browsers an earlier run already set up: those show **(set up)** and start unticked, so after installing another browser you just run the script again and it adds that one. Tick a set-up browser to redo it. Browsers that don't work on your system are listed but not ticked; you can still tick them to try.

**The Flatpak bridge and p11-kit versions:** the bridge is two halves of p11-kit, one on your system and one inside the Flatpak runtime. Ubuntu 24.04's p11-kit (0.25.3) is older than the runtimes', and once you've entered your PIN that mismatch garbles the card's keys and stops the bridge, so signing in to a site fails. So every Flatpak browser gets its own copy of a client that isn't newer than the bridge: on Debian and Ubuntu your system's client (same version as the bridge), on Fedora, which ships none, the browser's own runtime client (Fedora's bridge is newer, which works). The copy is adjusted so it uses its own address setting (keeping the runtime's built-in module from reaching the card a second time) and so its default address is the bridge (so the browser gets the card however it's started). With it, CAC sign-in works in the Ungoogled Chromium, Brave, Vivaldi and Firefox Flatpaks on Ubuntu 24.04.

- **How they're started doesn't matter.** A Flatpak browser reaches the card whether you start it from the app menu, a terminal or a link in another app. Restart any that were open while the script ran.
- **Firefox-based Flatpaks need a profile.** Start the browser once and close it before you run the script, or run the script again later. New profiles created afterwards don't get the CAC automatically.
- **Safety check:** a Firefox-based Flatpak built against the runtime's shared NSS library would lose its built-in root certificates through the bridge, so the script skips any that don't bundle their own NSS. The official Firefox build bundles its own.

**Ubuntu notes:**

- Ubuntu's Firefox is a **snap**. The script connects its `pcscd` interface (`snap connect firefox:pcscd`) and imports certificates into the snap profile. If Firefox still doesn't list your card, add the module by hand in *Settings → Privacy & Security → Security Devices → Load*, typing `/usr/lib/x86_64-linux-gnu/opensc-pkcs11.so` (don't use *Browse*). See [Ubuntu's guide](https://ubuntu.com/tutorials/enable-smart-cards-in-snapped-browsers).
- The Chromium **snap** brings its own OpenSC, but its base snap (core26) ships only the front half of pcsc-lite, which loads the real client from `libpcsclite_real.so.1`, and that file is missing, so the snap can't reach the card reader. The script copies your system's pcsc-lite client into `~/snap/chromium/common/` and points the snap at it with `LIBPCSCLITE_DELEGATE`, set in Chromium's menu entry (works right away) and for your whole session (after you log out and back in). Start Chromium from the app menu until then.
- Tested on Ubuntu 24.04: Firefox (snap and Mozilla's `.deb`), Google Chrome, the Chromium snap, and the Ungoogled Chromium, Brave, Vivaldi and Firefox Flatpaks. On Ubuntu 26.04: the same, plus the LibreWolf Flatpak, which doesn't work on 24.04. Army AVD works on both.
- OpenSC and `pcsc-tools` come from the `universe` repository, which is enabled by default on Ubuntu Desktop.

## Requirements

- An x86_64 Linux desktop running Fedora or Ubuntu (see above), and `sudo` access.
- A USB CAC reader. The generic CCID driver the script installs supports several hundred readers, which covers practically every CAC reader sold, for example:
  - SCM / Identiv SCR3310, SCR3500 and uTrust 2700
  - HID OMNIKEY 3021 and 3121
  - Thales / Gemalto IDBridge CT30, CT40 and K30, and the PC Twin
  - ACS ACR39U (older ACS readers such as the ACR38 get ACS's own driver, which the script installs when it sees one)
  - Cherry, IOGEAR GSR202, Saicoo and other CCID readers

  The script names your reader and says whether the driver knows it. A reader it doesn't know may still work as a generic CCID reader; if not, it needs its maker's Linux driver.
- An internet connection, used to download packages and the DISA certificate bundle.
- *Optional:* Flatpak browsers from [Flathub](https://flathub.org), installed **before** you run the script. Start Firefox-based ones once first so they have a profile.
- *For Army AVD:* an Army AVD assignment, plus a FreeRDP 3 package built with Azure AD support. The script checks this with `xfreerdp /buildconfig` and skips the launcher if it's missing.

## Install

```bash
git clone https://github.com/fracturedlogic17/cac_avd.git
cd cac_avd
sudo ./cac_setup.sh                 # interactive: detects, asks, confirms
sudo ./cac_setup.sh --user alice    # configure a specific desktop user
```

The interactive run looks like this:

```text
==> Detecting your system
  ✔ Fedora Linux 45 (Workstation Edition) (x86_64)
  ✔ Browsers: Firefox, Google Chrome, Ungoogled Chromium (Flatpak), Brave (Flatpak)

What do you want to set up?
  ↑/↓ move   Enter choose
    ( ) CAC only: smart card, DoD certificates and browsers
  > (•) CAC + Army AVD: also install the Army AVD desktop launcher
    ( ) Army AVD only: the launcher and what its CAC sign-in needs, no browsers

Which browsers should use your CAC?
  ↑/↓ move   Space select   Enter confirm
    [x] Firefox
    [x] Google Chrome
  > [ ] Ungoogled Chromium (Flatpak)
    [x] Brave (Flatpak)  (untested)

==> Ready to set up
    System:    Fedora Linux 45 (Workstation Edition) (x86_64), user alice
    Setup:     CAC + Army AVD launcher
    Browsers:  Firefox, Google Chrome, Brave (Flatpak)
    !          Brave (Flatpak): untested
Continue? [Y/n]
```

Close the browsers you chose before continuing. The script checks and waits until they're closed. Press Esc or `q` in a menu to cancel without changing anything.

**Options** (each one skips its question, which makes unattended runs possible):

| Option | Meaning |
|---|---|
| `--user NAME` | Desktop user to configure (default: the user who ran `sudo`) |
| `--avd` / `--no-avd` | CAC + Army AVD, or CAC only |
| `--avd-only` | Army AVD only: the smart card middleware, DoD certificates and the launcher, without setting up any browser |
| `--browsers LIST` | Comma-separated list, or `all` / `new` (only browsers not set up yet) / `none`. Native/Snap: `firefox`, `firefox-snap`, `chrome`, `chromium-snap`. Flatpak: `ungoogled-chromium`, `chromium-flatpak`, `chrome-flatpak`, `edge-flatpak`, `brave-flatpak`, `vivaldi-flatpak`, `opera-flatpak`, `firefox-flatpak`, `librewolf-flatpak`, `waterfox-flatpak`, `zen-flatpak`, `floorp-flatpak` |
| `--yes` | Skip the final confirmation |
| `--force` | Continue on an untested or unsupported distribution, version or CPU |

```bash
sudo ./cac_setup.sh --no-avd --browsers firefox,chrome --yes   # CAC for two browsers, no AVD
sudo ./cac_setup.sh --avd-only --yes                           # just Army AVD
```

Without a terminal (for example in a provisioning tool), the defaults are every detected browser plus AVD where it's available. The script exits instead of waiting if a browser it needs to configure is open.

You don't need your CAC inserted to run the script, and the card reader can be plugged in later too: setup completes either way. With the reader plugged in, the self-tests check that each browser can reach it; with the card inserted, they also check that the card shows up. Run the script from the cloned folder: it installs the launcher icon from `assets/`.

To update the certificates or repair the setup later, pull the latest version and run the script again.

## Using it

1. Quit and reopen your browsers completely. For the Chromium snap, use the app menu until you've logged out and back in once.
2. Open a CAC test page, such as <https://www.militarycac.com/testcac.htm>, or a site you normally sign in to with your CAC.
3. Choose your **authentication** certificate (not the email/signing one) and enter your PIN.

In Firefox, *Settings → Privacy & Security → Security Devices* should list your card under **p11-kit-proxy** (Fedora) or **CAC (OpenSC)** (Ubuntu and others).

## Army AVD launcher

Microsoft doesn't offer a Windows App or Remote Desktop client for Linux, so **Army AVD** connects with FreeRDP 3 through the Azure Government AVD feed instead.

<p align="center"><img src="assets/army-avd.svg" width="64" alt=""></p>

1. Open **Army AVD** from your app menu or the desktop icon.
2. Pick a desktop or app. Tick *Make this my default* if you want it to be your default, then click **Connect**.
3. When the sign-in window appears, choose your CAC authentication certificate and enter your PIN.

The app remembers your account, so later sign-ins are pre-filled or skipped. You can run several sessions at once, *Disconnect all* closes them, and *Clear sign-in…* forgets the saved sign-in and everything the sign-in window remembers (including the sign-in method you last picked) so you can start over or switch accounts.

There's also a command-line tool:

```bash
army-avd-qt                     # connect to your default desktop
army-avd-qt --choose            # pick again when several are assigned
army-avd-qt --login             # ignore the saved sign-in
army-avd-qt list                # print account and assigned resources as JSON
army-avd-qt logout              # forget the saved sign-in and cookies
army-avd-qt /f                  # extra arguments are passed to FreeRDP
```

| Environment variable | Purpose |
|---|---|
| `FREERDP` | Path to the FreeRDP binary. By default the tool uses `xfreerdp3`, then `xfreerdp`. |
| `AVD_TENANT` | Entra tenant (default `organizations`). |
| `AVD_LOGIN_HOST` | Sign-in host (default `login.microsoftonline.us`). |

Sessions use your CAC for smart card redirection (`/smartcard`), sound, microphone, clipboard and dynamic resolution.

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

## Troubleshooting

<details>
<summary><b>"This system isn't supported" or a browser isn't listed</b></summary>

The script only offers the systems and browsers in [Supported systems](#supported-systems). On an untested Fedora- or Debian-based distribution you can confirm the prompt, or pass `--force` when running without a terminal. Browsers marked *not yet* are detected but skipped. Use the browser's own settings, or a native package of the same browser.
</details>

<details>
<summary><b>"No reader visible to pcscd"</b></summary>

Unplug the reader, plug it back in and run `opensc-tool -l`. If it's still missing, run `sudo systemctl restart pcscd` and check `lsusb`.

If `journalctl -u pcscd` shows `LIBUSB_ERROR_ACCESS`, `pcscd` runs as its own user (as on Ubuntu 26.04) and isn't allowed to open the reader yet. Running the script again fixes this, as does unplugging and replugging the reader.
</details>

<details>
<summary><b>"Card reader … isn't on the CCID driver's list"</b></summary>

The reader identifies itself as a smart card reader, but the generic CCID driver doesn't list its model. Many such readers still work. If `opensc-tool -l` doesn't show it after you replug it, install its maker's Linux driver (look up the USB ID shown in the message, or the one `lsusb` prints for it). Older ACS readers are handled automatically: the script installs ACS's driver (`pcsc-lite-acsccid` on Fedora, `libacsccid1` on Ubuntu).
</details>

<details>
<summary><b>Firefox: "Unknown PKCS #11 error" or the card appears twice</b></summary>

OpenSC is being loaded twice. On Fedora, remove any manually added OpenSC entry under *Security Devices*, because p11-kit-proxy already provides it. Then run the script again.
</details>

<details>
<summary><b>Flatpak browser: no certificate offered, or <code>ERR_BAD_SSL_CLIENT_AUTH_CERT</code></b></summary>

Start the browser from its menu entry, which uses the wrapper, and make sure it was fully closed while the script ran. For a Firefox-based Flatpak, check that *Settings → Privacy & Security → Security Devices* lists **CAC (bridge)**. If the browser had no profile when the script ran, start it once, close it, and run the script again. To check the bridge:

```bash
systemctl --user status cac-p11-bridge.socket
journalctl --user -u 'cac-p11-bridge@*'
```
</details>

<details>
<summary><b>A site works in Chrome but shows a certificate warning in Firefox or a Flatpak browser</b></summary>

Some sites don't send their intermediate certificate. Chrome fetches missing ones itself; Firefox (until a new profile has downloaded its built-in list) and the Flatpak browsers don't. The script adds the ones known to be missing, such as the one for `*.hrc.army.mil`. For another site, add the intermediate's URL to `EXTRA_INTERMEDIATES` at the top of the script and run it again. Each one is only added if it chains to a root you already trust.
</details>

<details>
<summary><b>"FreeRDP 3 with AAD support not available"</b></summary>

Your FreeRDP build doesn't include Azure AD support. Check with `xfreerdp3 /buildconfig | grep AAD` (or `xfreerdp`). You need `WITH_AAD=ON`.
</details>

<details>
<summary><b>The PIN prompt stops after two wrong PINs</b></summary>

This is deliberate: the sign-in window stops before a third wrong PIN so it can't lock your CAC. Check your PIN and try again.
</details>

## Uninstall

There's no uninstall script yet. To undo everything by hand:

```bash
# Army AVD
rm -f ~/.local/bin/army-avd-{qt,gui} ~/.local/share/applications/army-avd-gui.desktop \
      ~/.local/share/icons/hicolor/scalable/apps/army-avd.svg "$(xdg-user-dir DESKTOP)/army-avd-gui.desktop"
rm -rf ~/.config/army-avd-qt ~/.local/share/army-avd-qt

# Chromium snap
rm -f ~/snap/chromium/common/libpcsclite_real.so.1 ~/.config/environment.d/90-cac-pcsclite.conf \
      ~/.local/share/applications/chromium_chromium.desktop
sudo snap disconnect chromium:pcscd

# Flatpak browsers and the bridge
for w in ~/.var/app/*/cac-launch.sh; do
  [ -e "$w" ] || continue
  app=$(basename "$(dirname "$w")")
  rm -f "$w" "$(dirname "$w")/cac-p11-client.so" ~/.local/share/applications/"$app".desktop
  flatpak override --user --nofilesystem=xdg-run/cac-p11 "$app"
done
systemctl --user disable --now cac-p11-bridge.socket
sudo rm -f /etc/systemd/user/cac-p11-bridge.socket /etc/systemd/user/cac-p11-bridge@.service

# System
sudo rm -f /etc/polkit-1/rules.d/90-cac-pcsc.rules
sudo rm -rf /usr/local/share/dod-pki
sudo rm -f /etc/pki/ca-trust/source/anchors/DoD_*.pem && sudo update-ca-trust extract           # Fedora
sudo rm -rf /usr/local/share/ca-certificates/dod && sudo update-ca-certificates --fresh         # Ubuntu
```

Then remove the `SecurityDevices` and `Certificates` entries from `/etc/firefox/policies/policies.json`, or delete the file if nothing else uses it. The certificates imported into browser profiles stay there until you delete them in each browser's certificate manager. In Firefox-based Flatpaks, also unload **CAC (bridge)** under *Security Devices*. The `--persist=.pki` Flatpak override is harmless to leave; `flatpak override --user --reset <app-id>` clears it along with any other overrides you set yourself.

## Security notes

- **Certificate trust:** the DoD bundle is installed only if its signed manifest chains to one of four DoD Root CA fingerprints written into the script, and the bundle's SHA-256 hash matches. Extra intermediates are added only if they chain to a root already in the system trust store.
- **Sign-in:** Army AVD uses the standard OAuth 2.0 authorization-code flow with PKCE against Microsoft's sign-in service for Azure Government. It sends access tokens only to `*.azure.us` and Microsoft sign-in hosts over HTTPS. The FreeRDP arguments, which include a token, go through an environment variable rather than the command line, so the token doesn't appear in `ps`.
- **Stored data:** the refresh token and account name are saved in `~/.config/army-avd-qt/` with mode 0600. `army-avd-qt logout` or *Clear sign-in…* deletes them, along with the sign-in window's cookies and cache.
- **Your PIN** is entered in the sign-in window and passed directly to NSS. It is never saved.
- **Card reader access:** the polkit rule lets processes running as your user use the card reader even outside the active desktop session, for example over SSH. The PIN is still required for every use.

Please report security issues privately rather than in a public issue.

## Disclaimer

This is an independent project. It is **not affiliated with, endorsed by or supported by** the U.S. Department of Defense, the U.S. Army, DISA or Microsoft. Follow your organization's policies on personal devices and remote access. Use it at your own risk.

## License

[MIT](LICENSE) © 2026 fracturedlogic17
