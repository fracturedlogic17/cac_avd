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
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [More documentation](#more-documentation)
- [Disclaimer](#disclaimer)
- [License](#license)

## What it does

- Installs the smart card middleware and finds your card reader.
- Downloads the official DISA DoD certificates, verifies them, and installs them system-wide and into your browsers.
- Sets up your browsers to use your CAC: native, Snap and Flatpak.
- Optionally installs **Army AVD**, a desktop launcher for Army Azure Virtual Desktop.

It's safe to run more than once. See [How it works](docs/how-it-works.md) for the details and every file it changes.

## Supported systems

| Distribution | Status |
|---|---|
| Fedora (recent releases) | ✅ Tested |
| Ubuntu 24.04 / 26.04 LTS | ✅ Tested |
| Debian 13 (trixie) | ✅ Tested |
| Linux Mint 22 | ✅ Tested |
| Newer Ubuntu releases | ⚠️ Untested |
| Ubuntu 22.04 | ❌ No Army AVD (browsers may work) |
| Other Fedora/Debian-based distributions | ⚠️ Untested, asks before continuing |
| Anything else (Arch, openSUSE…) | ❌ Not supported |

Works with Firefox, Chrome, Chromium, Edge, Brave, Vivaldi and more. See [Compatibility](docs/compatibility.md) for the per-browser, per-distribution results.

## Requirements

- An x86_64 Linux desktop running Fedora, Ubuntu, Debian or Linux Mint (see above), and `sudo` access.
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
sudo ./cac_setup.sh
```

Close the browsers you chose before continuing. You don't need your CAC inserted to run the script. To update the certificates or repair the setup later, pull the latest version and run the script again.

For command-line options and unattended runs, see [Advanced usage](docs/advanced-usage.md).

## Using it

1. Quit and reopen your browsers completely. For the Chromium snap, use the app menu until you've logged out and back in once.
2. Open a site you normally sign in to with your CAC.
3. Choose your **authentication** certificate (not the email/signing one) and enter your PIN.

In Firefox, *Settings → Privacy & Security → Security Devices* should list your card under **p11-kit-proxy** (Fedora) or **CAC (OpenSC)** (Ubuntu and others).

## Army AVD launcher

Microsoft doesn't offer a Windows App or Remote Desktop client for Linux, so **Army AVD** connects with FreeRDP 3 through the Azure Government AVD feed instead.

<p align="center"><img src="assets/army-avd.svg" width="64" alt=""></p>

1. Open **Army AVD** from your app menu or the desktop icon.
2. Pick a desktop or app. Tick *Make this my default* if you want it to be your default, then click **Connect**.
3. When the sign-in window appears, choose your CAC authentication certificate and enter your PIN.

For the command-line tool and its settings, see [Advanced usage](docs/advanced-usage.md#army-avd-details).

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

```bash
sudo ./cac_uninstall.sh
```

It shows what it found and asks before removing anything. Packages stay installed. See [Uninstall](docs/uninstall.md) for details.

## More documentation

- [Compatibility](docs/compatibility.md): tested distributions and browsers, Flatpak and Ubuntu notes
- [How it works](docs/how-it-works.md): each setup step, every file it changes, security notes
- [Advanced usage](docs/advanced-usage.md): options, unattended runs, the Army AVD command-line tool
- [Uninstall](docs/uninstall.md): what the uninstall script removes, and how to undo everything by hand

Please report security issues privately rather than in a public issue.

## Disclaimer

This is an independent project. It is **not affiliated with, endorsed by or supported by** the U.S. Department of Defense, the U.S. Army, DISA or Microsoft. Follow your organization's policies on personal devices and remote access. Use it at your own risk.

## License

[MIT](LICENSE) © 2026 fracturedlogic17
