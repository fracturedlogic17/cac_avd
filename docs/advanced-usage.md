# Advanced usage

[← Back to README](../README.md)

## Interactive run

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

## Army AVD details

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
