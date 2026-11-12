# Uninstall

[← Back to README](../README.md)

Run the uninstall script from the cloned folder:

```bash
sudo ./cac_uninstall.sh                 # shows what it found and asks before changing anything
sudo ./cac_uninstall.sh --user alice    # clean up a specific desktop user
sudo ./cac_uninstall.sh --yes           # don't ask
```

It removes the Army AVD launcher (including its saved sign-in), the DoD certificates and CAC modules from your browsers' certificate stores, the Flatpak bridge and the Chromium snap fix, the Firefox policy entries, the DoD roots in the system trust store and the other system files listed in [How it works](how-it-works.md#what-gets-changed-on-your-system). Close your browsers first.

Packages stay installed, because some of them (p11-kit, NSS tools, OpenSSL, curl, Python) are used by other software too. At the end, the script prints the command to remove the smart card and Army AVD packages if you want to.

## Removing it by hand

If you'd rather undo everything yourself:

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
