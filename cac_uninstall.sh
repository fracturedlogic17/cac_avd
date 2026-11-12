#!/usr/bin/env bash
# cac_uninstall.sh - Undo what cac_setup.sh set up: the Army AVD launcher, the browser setup
# (DoD certificates, CAC modules, the Flatpak bridge and the Chromium snap fix), the DoD
# certificates in the system trust store and the system files it wrote.
#
# Usage:  sudo ./cac_uninstall.sh [options]
#
#   --user NAME   desktop user to clean up (default: the user who ran sudo)
#   --yes         don't ask for confirmation before making changes
#
# Packages are left installed: some (p11-kit, NSS tools, OpenSSL, curl, Python) are used by other
# software too. The script lists the smart card and Army AVD ones at the end so you can remove them.
# Close your browsers first. Safe to re-run; anything already removed is skipped.

set -euo pipefail

# ---------------------------------------------------------------- settings (match cac_setup.sh)
CERT_DIR="/usr/local/share/dod-pki"
MODULE_NAME="CAC (OpenSC)"
BRIDGE_NAME="CAC (bridge)"
POLICIES=(/etc/firefox/policies/policies.json /etc/firefox-esr/policies/policies.json)
POLKIT_RULE=/etc/polkit-1/rules.d/90-cac-pcsc.rules
BRIDGE_UNITS=(/etc/systemd/user/cac-p11-bridge.socket /etc/systemd/user/cac-p11-bridge@.service)
FEDORA_ANCHORS=/etc/pki/ca-trust/source/anchors
DEBIAN_ANCHORS=/usr/local/share/ca-certificates/dod
BACKPORTS=/etc/apt/sources.list.d/debian-backports.sources

# ---------------------------------------------------------------- helpers
c_info=$'\e[1;34m'; c_ok=$'\e[1;32m'; c_warn=$'\e[1;33m'; c_err=$'\e[1;31m'; c_off=$'\e[0m'
info() { printf '%s==>%s %s\n' "$c_info" "$c_off" "$*"; }
ok()   { printf '%s  ✔%s %s\n' "$c_ok" "$c_off" "$*"; }
warn() { printf '%s  !%s %s\n' "$c_warn" "$c_off" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }

as_user() { runuser -u "$TARGET_USER" -- "$@"; }
user_systemctl() {
  as_user env XDG_RUNTIME_DIR="/run/user/$TARGET_UID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$TARGET_UID/bus" systemctl --user "$@"
}
confirm() {
  local ans hint="[y/N]"
  [[ $2 == y ]] && hint="[Y/n]"
  read -rp "$1 $hint " ans </dev/tty || ans=""
  ans=${ans:-$2}
  [[ $ans == [yY]* ]]
}

# ---------------------------------------------------------------- args/env
TARGET_USER="${SUDO_USER:-}"
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) [[ $# -ge 2 ]] || die "--user needs a name"; TARGET_USER="$2"; shift 2 ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo $0"
[[ -n "$TARGET_USER" && "$TARGET_USER" != root ]] || die "Could not determine your desktop user. Use: sudo $0 --user <name>"
id "$TARGET_USER" &>/dev/null || die "User '$TARGET_USER' does not exist"
TARGET_UID=$(id -u "$TARGET_USER")
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
[[ -n $TARGET_HOME && -d $TARGET_HOME ]] || die "Home folder of '$TARGET_USER' not found"
INTERACTIVE=0
[[ -t 0 ]] && INTERACTIVE=1
APPS_DIR="$TARGET_HOME/.local/share/applications"

# ================================================================ 0. find what's installed
info "Looking for what cac_setup.sh set up for $TARGET_USER"
FOUND=()

AVD_FILES=()
for f in "$TARGET_HOME"/.local/bin/army-avd-{qt,gui,feed,freerdp} \
         "$APPS_DIR"/army-avd{,-gui,-freerdp,-qt}.desktop \
         "$TARGET_HOME/.local/share/icons/hicolor/scalable/apps/army-avd.svg" \
         "$TARGET_HOME/.config/army-avd-qt" "$TARGET_HOME/.local/share/army-avd-qt"; do
  [[ -e $f ]] && AVD_FILES+=("$f")
done
DESKTOP_DIR=$(as_user xdg-user-dir DESKTOP 2>/dev/null || echo "$TARGET_HOME/Desktop")
if [[ -d $DESKTOP_DIR && $DESKTOP_DIR != "$TARGET_HOME" ]]; then
  for f in "$DESKTOP_DIR"/army-avd-{gui,freerdp,qt}.desktop; do [[ -e $f ]] && AVD_FILES+=("$f"); done
fi
[[ ${#AVD_FILES[@]} -gt 0 ]] && FOUND+=("Army AVD launcher, its saved sign-in and settings")

# NSS certificate stores the setup may have written to: Firefox profiles (native, snap, Flatpak),
# ~/.pki/nssdb (native Chrome family and the AVD sign-in window), the Chromium snap's and each
# Flatpak's. Symlinks (~/snap/chromium/current) are skipped so no store is handled twice.
NSS_DBS=()
while IFS= read -r db; do NSS_DBS+=("$(dirname "$db")"); done < <(
  find "$TARGET_HOME/.mozilla/firefox" "$TARGET_HOME/.config/mozilla/firefox" \
       "$TARGET_HOME/snap/firefox/common/.mozilla/firefox" \
       -mindepth 2 -maxdepth 2 -name cert9.db 2>/dev/null || true
  [[ -f $TARGET_HOME/.pki/nssdb/cert9.db ]] && echo "$TARGET_HOME/.pki/nssdb/cert9.db"
  find "$TARGET_HOME/snap/chromium" -mindepth 4 -maxdepth 4 -path '*/.pki/nssdb/cert9.db' 2>/dev/null \
    | grep -v '/snap/chromium/current/' || true
  find "$TARGET_HOME/.var/app" -mindepth 3 -maxdepth 7 -name cert9.db 2>/dev/null || true
)
NICKS=()
if [[ -d $CERT_DIR ]]; then
  for f in "$CERT_DIR"/roots/*.pem "$CERT_DIR"/intermediates/*.pem "$CERT_DIR"/extra/*.pem; do
    [[ -f $f ]] && NICKS+=("$(basename "${f%.pem}" | tr '_' ' ')")
  done
fi
[[ ${#NSS_DBS[@]} -gt 0 ]] && FOUND+=("DoD certificates and CAC modules from ${#NSS_DBS[@]} browser certificate store(s) (only those this project added)")

FP_APPS=()
for w in "$TARGET_HOME"/.var/app/*/cac-launch.sh "$TARGET_HOME"/.var/app/*/chromium-cac.sh; do
  [[ -e $w ]] || continue
  app=$(basename "$(dirname "$w")")
  [[ " ${FP_APPS[*]} " == *" $app "* ]] || FP_APPS+=("$app")
done
[[ ${#FP_APPS[@]} -gt 0 ]] && FOUND+=("CAC setup of ${#FP_APPS[@]} Flatpak browser(s): ${FP_APPS[*]}")
[[ -e ${BRIDGE_UNITS[0]} || -e ${BRIDGE_UNITS[1]} ]] && FOUND+=("PKCS#11 bridge for Flatpak browsers")

SNAP_CHROMIUM=0
if [[ -e $TARGET_HOME/snap/chromium/common/libpcsclite_real.so.1 \
      || -e $TARGET_HOME/.config/environment.d/90-cac-pcsclite.conf ]] \
   || grep -qs LIBPCSCLITE_DELEGATE "$APPS_DIR/chromium_chromium.desktop"; then
  SNAP_CHROMIUM=1; FOUND+=("Chromium snap card reader fix")
fi
SNAPS=()
if command -v snap &>/dev/null; then
  for s in firefox chromium; do
    snap connections "$s" 2>/dev/null | grep -qE "^[a-z-]+ +$s:pcscd +:" && SNAPS+=("$s")
  done
fi
[[ ${#SNAPS[@]} -gt 0 ]] && FOUND+=("pcscd connection of snap(s): ${SNAPS[*]}")

POLICY_FILES=()
for p in "${POLICIES[@]}"; do
  grep -qs -e "$CERT_DIR" -e "\"$MODULE_NAME\"" "$p" && POLICY_FILES+=("$p")
done
[[ ${#POLICY_FILES[@]} -gt 0 ]] && FOUND+=("Firefox enterprise policy entries: ${POLICY_FILES[*]}")

TRUST=0
compgen -G "$FEDORA_ANCHORS/DoD_*.pem" >/dev/null && TRUST=1
[[ -d $DEBIAN_ANCHORS ]] && TRUST=1
[[ $TRUST == 1 ]] && FOUND+=("DoD root certificates in the system trust store")
[[ -d $CERT_DIR ]] && FOUND+=("Downloaded DoD certificates in $CERT_DIR")
grep -qs "cac_setup.sh" "$POLKIT_RULE" && FOUND+=("polkit rule $POLKIT_RULE")

if [[ ${#FOUND[@]} -eq 0 ]]; then
  ok "Nothing from cac_setup.sh found for $TARGET_USER; nothing to do."
  exit 0
fi

echo
info "This will remove"
for f in "${FOUND[@]}"; do echo "    - $f"; done
echo "    Packages stay installed."
if [[ ${#NSS_DBS[@]} -gt 0 && ${#NICKS[@]} -eq 0 ]]; then
  warn "$CERT_DIR is missing, so the DoD certificates in browser stores can't be identified;"
  warn "they'll stay there (delete them in each browser's certificate manager)."
fi
if [[ $ASSUME_YES == 0 ]]; then
  [[ $INTERACTIVE == 1 ]] || die "Not running in a terminal; re-run with --yes to confirm."
  confirm "Continue?" n || die "Cancelled; nothing was changed."
fi

# ---------------------------------------------------------------- browsers must be closed
# A running browser keeps its certificate store open and rewrites its module list on exit.
running_apps() {
  pgrep -u "$TARGET_USER" -l 2>/dev/null | awk '{print $2}' | grep -xE \
    'firefox|firefox-bin|firefox-esr|librewolf|waterfox|floorp|zen|zen-bin|chrome|chromium|chromium-browse|msedge|brave|vivaldi-bin|opera' \
    | sort -u | paste -sd, - || true
  pgrep -u "$TARGET_USER" -f '/\.local/bin/army-avd-(gui|qt)' >/dev/null && echo "Army AVD"
  return 0
}
RUNNING=$(running_apps)
while [[ -n $RUNNING ]]; do
  warn "Close these first (all windows): ${RUNNING//$'\n'/, }"
  [[ $INTERACTIVE == 1 ]] || die "Browsers are running; close them and run the script again."
  read -rp "    Press Enter once they are closed... " _
  RUNNING=$(running_apps)
done

# ================================================================ 1. Army AVD
if [[ ${#AVD_FILES[@]} -gt 0 ]]; then
  info "Removing the Army AVD launcher"
  rm -rf "${AVD_FILES[@]}"
  as_user update-desktop-database "$APPS_DIR" 2>/dev/null || true
  as_user gtk-update-icon-cache -f -t "$TARGET_HOME/.local/share/icons/hicolor" &>/dev/null || true
  ok "Army AVD removed, including its saved sign-in"
fi

# ================================================================ 2. browser certificate stores
# Every certutil run loads the modules in the store's pkcs11.txt, and OpenSC wakes the card reader,
# which can take seconds per run; so the module list is set aside while the certificates go.
PKCS11_ASIDE=""
restore_pkcs11() { [[ -n $PKCS11_ASIDE ]] && mv -f "$PKCS11_ASIDE" "${PKCS11_ASIDE%.cac-uninstall}"; PKCS11_ASIDE=""; return 0; }
trap restore_pkcs11 EXIT
# drop_cac_modules PKCS11_TXT: remove this project's CAC modules from an NSS module list.
drop_cac_modules() {
  as_user python3 -I - "$1" "$MODULE_NAME" "$BRIDGE_NAME" <<'EOF'
import re, sys
path, names = sys.argv[1], sys.argv[2:]
text = open(path).read()
entries = [e for e in re.split(r"\n\s*\n", text) if e.strip()]
keep = [e for e in entries
        if not any(re.search(rf"^name={re.escape(n)}$", e, re.M) for n in names)
        and not re.search(r"^library=.*cac-p11-client\.so$", e, re.M)]
if len(keep) != len(entries):
    open(path, "w").write("\n\n".join(keep) + "\n")
EOF
}
if [[ ${#NSS_DBS[@]} -gt 0 ]]; then
  info "Removing DoD certificates and CAC modules from browser certificate stores"
  for db in "${NSS_DBS[@]}"; do
    if [[ ${#NICKS[@]} -gt 0 ]]; then
      if [[ -f $db/pkcs11.txt ]]; then
        PKCS11_ASIDE="$db/pkcs11.txt.cac-uninstall"
        mv "$db/pkcs11.txt" "$PKCS11_ASIDE"
      fi
      present=$(as_user certutil -L -d "sql:$db" 2>/dev/null || true)
      for nick in "${NICKS[@]}"; do
        # A nickname can hold more than one certificate; delete until none is left.
        if [[ $present == *"$nick "* ]]; then
          while as_user certutil -D -d "sql:$db" -n "$nick" &>/dev/null; do :; done
        fi
      done
      rm -f "$db/pkcs11.txt"
      restore_pkcs11
    fi
    [[ -f $db/pkcs11.txt ]] && drop_cac_modules "$db/pkcs11.txt"
    ok "${db#"$TARGET_HOME"/}"
  done
fi

# ================================================================ 3. Flatpak browsers and the bridge
# drop_bridge_override APP: take the bridge socket out of the app's Flatpak overrides. Other
# overrides stay, including --persist=.pki, which only keeps the app's own certificate store.
drop_bridge_override() {
  local f="$TARGET_HOME/.local/share/flatpak/overrides/$1"
  [[ -f $f ]] || return 0
  as_user python3 -I - "$f" <<'EOF'
import os, re, sys
path = sys.argv[1]
lines = open(path).read().splitlines()
out = []
for line in lines:
    m = re.match(r"filesystems=(.*)$", line)
    if m:
        keep = [x for x in m.group(1).split(";") if x and x.lstrip("!") != "xdg-run/cac-p11"]
        if not keep:
            continue
        line = "filesystems=" + ";".join(keep) + ";"
    out.append(line)
# Drop sections left empty, then the file if nothing is left.
text = re.sub(r"^\[[^\]]+\]\n(?=\[|\Z)", "", "\n".join(out) + "\n", flags=re.M).strip()
if text:
    open(path, "w").write(text + "\n")
else:
    os.remove(path)
EOF
}
if [[ ${#FP_APPS[@]} -gt 0 ]]; then
  info "Removing the CAC setup from Flatpak browsers"
  for app in "${FP_APPS[@]}"; do
    appdir="$TARGET_HOME/.var/app/$app"
    rm -f "$appdir/cac-launch.sh" "$appdir/chromium-cac.sh" "$appdir/cac-p11-client.so" \
          "$appdir/.runtime-p11-kit-client.so"
    grep -qs -e cac-launch.sh -e chromium-cac.sh "$APPS_DIR/$app.desktop" && rm -f "$APPS_DIR/$app.desktop"
    drop_bridge_override "$app"
    ok "$app"
  done
  as_user update-desktop-database "$APPS_DIR" 2>/dev/null || true
fi
if [[ -e ${BRIDGE_UNITS[0]} || -e ${BRIDGE_UNITS[1]} ]]; then
  info "Removing the PKCS#11 bridge"
  systemctl --global disable cac-p11-bridge.socket >/dev/null 2>&1 || true
  if [[ -S "/run/user/$TARGET_UID/bus" ]]; then
    user_systemctl stop cac-p11-bridge.socket >/dev/null 2>&1 || true
  fi
  rm -f "${BRIDGE_UNITS[@]}"
  [[ -S "/run/user/$TARGET_UID/bus" ]] && user_systemctl daemon-reload >/dev/null 2>&1 || true
  ok "Bridge removed"
fi

# ================================================================ 4. snaps
if [[ $SNAP_CHROMIUM == 1 ]]; then
  info "Removing the Chromium snap card reader fix"
  rm -f "$TARGET_HOME/snap/chromium/common/libpcsclite_real.so.1" \
        "$TARGET_HOME/.config/environment.d/90-cac-pcsclite.conf"
  # The menu entry is a copy of the snap's own with the fix added; the snap's own takes over again.
  grep -qs LIBPCSCLITE_DELEGATE "$APPS_DIR/chromium_chromium.desktop" && rm -f "$APPS_DIR/chromium_chromium.desktop"
  ok "Chromium snap fix removed (the session setting goes at your next login)"
fi
for s in "${SNAPS[@]}"; do
  snap disconnect "$s:pcscd" 2>/dev/null && ok "Snap $s: pcscd interface disconnected" \
    || warn "Could not disconnect $s:pcscd; run: sudo snap disconnect $s:pcscd"
done

# ================================================================ 5. system
info "Removing system files"
for p in "${POLICY_FILES[@]}"; do
  python3 -I - "$p" "$MODULE_NAME" "$CERT_DIR" <<'PY'
import json, os, sys
path, name, certdir = sys.argv[1:]
with open(path) as fh:
    data = json.load(fh)
pol = data.get("policies", {})
add = pol.get("SecurityDevices", {}).get("Add", {})
add.pop(name, None)
if not add:
    pol.get("SecurityDevices", {}).pop("Add", None)
if "SecurityDevices" in pol and not pol["SecurityDevices"]:
    pol.pop("SecurityDevices")
certs = pol.get("Certificates", {})
if "Install" in certs:
    certs["Install"] = [p for p in certs["Install"] if not p.startswith(certdir)]
    if not certs["Install"]:
        certs.pop("Install")
if "Certificates" in pol and not certs:
    pol.pop("Certificates")
if not pol:
    data.pop("policies", None)
if data:
    with open(path, "w") as fh:
        json.dump(data, fh, indent=2)
else:
    os.remove(path)
PY
  ok "Firefox policy cleaned: $p"
done
if [[ $TRUST == 1 ]]; then
  if compgen -G "$FEDORA_ANCHORS/DoD_*.pem" >/dev/null; then
    rm -f "$FEDORA_ANCHORS"/DoD_*.pem
    update-ca-trust extract
  fi
  if [[ -d $DEBIAN_ANCHORS ]]; then
    rm -rf "$DEBIAN_ANCHORS"
    update-ca-certificates --fresh >/dev/null
  fi
  ok "DoD roots removed from the system trust store"
fi
if [[ -d $CERT_DIR ]]; then
  rm -rf "$CERT_DIR"
  ok "Removed $CERT_DIR"
fi
if grep -qs "cac_setup.sh" "$POLKIT_RULE"; then
  rm -f "$POLKIT_RULE"
  ok "Removed $POLKIT_RULE"
fi

# ================================================================ summary
echo
info "Done. Restart your browsers."
if command -v dnf &>/dev/null; then
  pkgs="pcsc-lite-ccid opensc pcsc-tools freerdp python3-pyqt6-webengine"
  echo "    To also remove the smart card and Army AVD packages:  sudo dnf remove $pkgs"
else
  pkgs="libccid opensc opensc-pkcs11 pcsc-tools freerdp3-x11 python3-pyqt6.qtwebengine"
  echo "    To also remove the smart card and Army AVD packages:  sudo apt-get remove $pkgs"
fi
echo "    Check the list first: other software may use them."
if grep -qs "cac_setup.sh" "$BACKPORTS"; then
  echo "    cac_setup.sh also added Debian's backports source ($BACKPORTS) for FreeRDP."
  echo "    Remove it after removing FreeRDP if you don't want backports."
fi
