# Compatibility

[← Back to README](../README.md)

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
