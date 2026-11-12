#!/usr/bin/env bash
# cac_setup.sh - Set up a DoD CAC on Linux: smart card middleware, DoD PKI roots and the
# browsers you pick, plus (optionally) the Army AVD launcher (FreeRDP with CAC sign-in).
#
# Usage:  sudo ./cac_setup.sh [options]
#
# Without options it detects your system and installed browsers, then asks what to set up.
#   --user NAME        desktop user to configure (default: the user who ran sudo)
#   --avd | --no-avd   set up the Army AVD launcher, or CAC only (skips the question)
#   --avd-only         set up only what Army AVD needs: the smart card middleware, the DoD
#                      certificates and the launcher, without any browser (skips both questions)
#   --browsers LIST    comma-separated browsers to configure, 'all', 'new' or 'none' (skips the question):
#                        firefox             Firefox (native package)
#                        firefox-snap        Firefox (Snap, Ubuntu)
#                        chrome              Chrome/Chromium/Edge/Brave/Vivaldi (native; shared cert store)
#                        chromium-snap       Chromium (Snap, Ubuntu)
#                        ungoogled-chromium  Ungoogled Chromium (Flatpak)
#                        chromium-flatpak, chrome-flatpak, edge-flatpak, brave-flatpak,
#                        vivaldi-flatpak, opera-flatpak, firefox-flatpak, librewolf-flatpak,
#                        waterfox-flatpak, zen-flatpak, floorp-flatpak   (Flathub browsers)
#                      'all' skips browsers known not to work on this system (currently the
#                      LibreWolf Flatpak on Ubuntu 24.04 and Linux Mint 22); name one
#                      explicitly to try it anyway. 'new' is like 'all' but
#                      also skips browsers an earlier run already set up.
#                      Asked interactively, browsers already set up start unticked, so a
#                      re-run after installing a new browser just adds that one.
#   --yes             don't ask for confirmation before making changes
#   --force            continue on a distribution or version this script doesn't support
#
# Close the browsers being configured first. Safe to re-run; every step is idempotent.

set -euo pipefail

# ---------------------------------------------------------------- settings
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOD_ZIP_URL="https://dl.dod.cyber.mil/wp-content/uploads/pki-pke/zip/unclass-certificates_pkcs7_DoD.zip"
CERT_DIR="/usr/local/share/dod-pki"
# Flatpak browsers this script can set up: option id | Flatpak app ID | name | engine.
FLATPAK_BROWSERS=(
  "ungoogled-chromium|io.github.ungoogled_software.ungoogled_chromium|Ungoogled Chromium|chromium"
  "chromium-flatpak|org.chromium.Chromium|Chromium|chromium"
  "chrome-flatpak|com.google.Chrome|Google Chrome|chromium"
  "edge-flatpak|com.microsoft.Edge|Microsoft Edge|chromium"
  "brave-flatpak|com.brave.Browser|Brave|chromium"
  "vivaldi-flatpak|com.vivaldi.Vivaldi|Vivaldi|chromium"
  "opera-flatpak|com.opera.Opera|Opera|chromium"
  "firefox-flatpak|org.mozilla.firefox|Firefox|firefox"
  "librewolf-flatpak|io.gitlab.librewolf-community|LibreWolf|firefox"
  "waterfox-flatpak|net.waterfox.waterfox|Waterfox|firefox"
  "zen-flatpak|app.zen_browser.zen|Zen Browser|firefox"
  "floorp-flatpak|one.ablaze.floorp|Floorp|firefox"
)
# Public intermediates that some Army/DoD sites fail to send. Chrome fetches missing ones itself,
# but Firefox (a new profile hasn't downloaded its preloaded intermediates yet) and the Flatpak
# Chromiums don't, so they go into every NSS DB this script sets up.
EXTRA_INTERMEDIATES=(
  "http://cacerts.digicert.com/DigiCertGlobalG2TLSRSASHA2562020CA1-1.crt"  # *.hrc.army.mil
)
MODULE_NAME="CAC (OpenSC)"

# SHA-256 fingerprints of the DoD Root CAs allowed to sign the bundle manifest.
PINNED_ROOTS=(
  "B1:07:B3:3F:45:3E:55:10:F6:8E:51:31:10:C6:F6:94:4B:AC:C2:63:DF:01:37:F8:21:C1:B3:C2:F8:F8:63:D2" # DoD Root CA 3
  "55:9A:51:89:45:2B:13:F8:23:3F:00:22:36:3C:06:F2:6E:3C:51:7C:1D:4B:77:44:50:35:95:9D:F3:24:4F:74" # DoD Root CA 4
  "1F:4E:DE:9D:C2:A2:41:F6:52:1B:F5:18:42:4A:CD:49:EB:E8:44:20:E6:9D:AF:5B:AC:57:AF:1F:8E:E2:94:A9" # DoD Root CA 5
  "2A:5E:41:AC:A9:3D:F7:CC:49:6D:23:69:B7:A0:A0:37:04:5D:50:2F:1A:BA:AF:76:97:5F:C0:7C:66:60:CF:93" # DoD Root CA 6
)

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

version_ge() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$2" ]]; }
join() { local out="" s; for s in "${@:2}"; do out+="${out:+$1}$s"; done; printf '%s' "$out"; }

WORK=""
CERT_SRC_DB=""
cleanup() {
  [[ -n "$WORK" ]] && rm -rf "$WORK"
  [[ -n "$CERT_SRC_DB" ]] && rm -rf "$CERT_SRC_DB"
  [[ -t 0 ]] && printf '\e[?25h' 2>/dev/null >/dev/tty   # cursor back, if a menu hid it
  return 0
}
trap cleanup EXIT

# Arrow-key menu: Up/Down (or k/j) move, Enter confirms, Esc or q cancels. With multi=1, Space
# toggles items and MENU_ON holds one 0/1 per item (preset by the caller); otherwise
# MENU_CHOICE is the index of the highlighted item.
menu() {
  local multi="$1" title="$2"; shift 2
  local -a items=("$@")
  local n=${#items[@]} cur=0 i key rest mark redraw=0
  printf '\n%s%s%s\n' "$c_info" "$title" "$c_off" >/dev/tty
  if [[ $multi == 1 ]]; then
    printf '  ↑/↓ move   Space select   Enter confirm\n' >/dev/tty
  else
    printf '  ↑/↓ move   Enter choose\n' >/dev/tty
  fi
  printf '\e[?25l' >/dev/tty
  while :; do
    [[ $redraw == 1 ]] && printf '\e[%dA' "$n" >/dev/tty
    redraw=1
    for ((i = 0; i < n; i++)); do
      if [[ $multi == 1 ]]; then
        [[ ${MENU_ON[i]} == 1 ]] && mark='[x]' || mark='[ ]'
      else
        [[ $i == "$cur" ]] && mark='(•)' || mark='( )'
      fi
      if [[ $i == "$cur" ]]; then
        printf '\r\e[K  %s> %s %s%s\n' "$c_ok" "$mark" "${items[i]}" "$c_off" >/dev/tty
      else
        printf '\r\e[K    %s %s\n' "$mark" "${items[i]}" >/dev/tty
      fi
    done
    IFS= read -rsn1 key </dev/tty || key=q
    if [[ $key == $'\e' ]]; then
      IFS= read -rsn2 -t 0.05 rest </dev/tty || rest=""
      key+=$rest
    fi
    case "$key" in
      $'\e[A'|$'\eOA'|k) cur=$(( (cur + n - 1) % n )) ;;
      $'\e[B'|$'\eOB'|j) cur=$(( (cur + 1) % n )) ;;
      ' ') if [[ $multi == 1 ]]; then MENU_ON[cur]=$(( 1 - MENU_ON[cur] )); fi ;;
      '') break ;;
      q|Q|$'\e') printf '\e[?25h' >/dev/tty; die "Cancelled; nothing was changed." ;;
    esac
  done
  printf '\e[?25h' >/dev/tty
  MENU_CHOICE=$cur
}

# Yes/no question; $2 is the default answer (y or n).
confirm() {
  local ans hint="[y/N]"
  [[ $2 == y ]] && hint="[Y/n]"
  read -rp "$1 $hint " ans </dev/tty || ans=""
  ans=${ans:-$2}
  [[ $ans == [yY]* ]]
}

# ---------------------------------------------------------------- args/env
TARGET_USER="${SUDO_USER:-}"
WANT_AVD=""      # 1 = CAC + AVD, 0 = CAC only, empty = ask
AVD_ONLY=0       # 1 = Army AVD without any browser
BROWSER_ARG=""   # --browsers value; empty = ask
ASSUME_YES=0
FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) [[ $# -ge 2 ]] || die "--user needs a name"; TARGET_USER="$2"; shift 2 ;;
    --avd) WANT_AVD=1; shift ;;
    --no-avd) WANT_AVD=0; shift ;;
    --avd-only) WANT_AVD=1; AVD_ONLY=1; shift ;;
    --browsers) [[ $# -ge 2 ]] || die "--browsers needs a list"; BROWSER_ARG="$2"; shift 2 ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo $0"
[[ -n "$TARGET_USER" && "$TARGET_USER" != root ]] || die "Could not determine your desktop user. Use: sudo $0 --user <name>"
id "$TARGET_USER" &>/dev/null || die "User '$TARGET_USER' does not exist"
TARGET_UID=$(id -u "$TARGET_USER")
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
INTERACTIVE=0
[[ -t 0 ]] && INTERACTIVE=1

# ================================================================ 0. detect
info "Detecting your system"
[[ -r /etc/os-release ]] || die "Can't identify this Linux distribution (/etc/os-release is missing)."
eval "$(. /etc/os-release; printf 'OS_ID=%q OS_LIKE=%q OS_VER=%q OS_NAME=%q OS_CODENAME=%q' \
  "${ID:-}" "${ID_LIKE:-}" "${VERSION_ID:-}" "${PRETTY_NAME:-${NAME:-Linux}}" "${VERSION_CODENAME:-}")"
ARCH=$(uname -m)
UNSUPPORTED=()   # reasons this system is outside what the script supports
case "$OS_ID" in
  fedora) PKG=dnf; version_ge "$OS_VER" 41 || UNSUPPORTED+=("Fedora $OS_VER is older than 41") ;;
  ubuntu) PKG=apt; version_ge "$OS_VER" 24.04 || UNSUPPORTED+=("Ubuntu $OS_VER is older than 24.04") ;;
  debian) PKG=apt; version_ge "${OS_VER:-0}" 13 || UNSUPPORTED+=("Debian ${OS_VER:-testing/unstable} is older than 13 or untested") ;;
  linuxmint) PKG=apt; version_ge "$OS_VER" 22 || UNSUPPORTED+=("Linux Mint $OS_VER is older than 22") ;;
  *)
    if [[ " $OS_LIKE " == *" fedora "* ]] && command -v dnf &>/dev/null; then
      PKG=dnf; UNSUPPORTED+=("$OS_NAME is Fedora-based but untested")
    elif [[ " $OS_ID $OS_LIKE " == *" ubuntu "* || " $OS_ID $OS_LIKE " == *" debian "* ]] \
         && command -v apt-get &>/dev/null; then
      PKG=apt; UNSUPPORTED+=("$OS_NAME is Debian/Ubuntu-based but untested")
    else
      die "$OS_NAME isn't supported. This script supports Fedora 41+, Ubuntu 24.04+, Debian 13+ and Linux Mint 22+."
    fi ;;
esac
[[ $ARCH == x86_64 ]] || UNSUPPORTED+=("$ARCH CPUs aren't supported (x86_64 only)")
ok "$OS_NAME ($ARCH)"
if [[ ${#UNSUPPORTED[@]} -gt 0 ]]; then
  for r in "${UNSUPPORTED[@]}"; do warn "$r."; done
  if [[ $FORCE == 1 ]]; then
    warn "Continuing because of --force."
  elif [[ $INTERACTIVE == 1 ]]; then
    confirm "This system isn't supported. Continue anyway?" n || die "Stopped; nothing was changed."
  else
    die "This system isn't supported; re-run with --force to try anyway."
  fi
fi

# Everything the script uses comes from these packages; the AVD set only when AVD is chosen.
if [[ $PKG == dnf ]]; then
  BASE_PKGS=(pcsc-lite pcsc-lite-ccid opensc p11-kit p11-kit-server nss-tools openssl unzip curl
             python3 usbutils pcsc-tools procps-ng ca-certificates)
  AVD_PKGS=(freerdp python3-pyqt6-webengine desktop-file-utils xdg-user-dirs)
  AVD_AVAILABLE=1
else
  BASE_PKGS=(pcscd libccid opensc opensc-pkcs11 p11-kit p11-kit-modules libnss3-tools openssl unzip curl
             python3 usbutils pcsc-tools procps ca-certificates)
  AVD_PKGS=(freerdp3-x11 python3-pyqt6.qtwebengine desktop-file-utils xdg-user-dirs)
  apt-get update -qq || die "apt-get update failed; check your internet connection and apt sources."
  AVD_AVAILABLE=1
  for p in "${AVD_PKGS[@]}"; do
    policy=$(apt-cache policy "$p" 2>/dev/null || true)
    [[ $policy == *"Candidate: "[!\(]* ]] || AVD_AVAILABLE=0
  done
fi

# ---- browsers. Supported ones get an id, a label, a 'pgrep -f' pattern for "is it running" and
# a test status: "" (works), "untested" or "broken" (tried on this kind of system, doesn't work yet).
# Snaps and Flatpaks on Ubuntu were tested on 24.04 and 26.04; other releases count as untested.
UBUNTU_REL=""
[[ $OS_ID == ubuntu ]] && UBUNTU_REL=$OS_VER
DEBIAN_TESTED=0   # Debian 13 and Linux Mint 22: no snaps there; Flatpaks tested as below
[[ $OS_ID == debian && $OS_VER == 13 ]] && DEBIAN_TESTED=1
MINT_TESTED=0
[[ $OS_ID == linuxmint && ${OS_VER%%.*} == 22 ]] && MINT_TESTED=1
browser_status() {
  case "$1" in
    firefox|firefox-snap|chrome) echo "" ;;
    chromium-snap)
      if [[ $UBUNTU_REL == 24.04 || $UBUNTU_REL == 26.04 ]]; then echo ""; else echo untested; fi ;;
    # Flatpaks reach the card through the bridge: tested with Ungoogled Chromium, Vivaldi and
    # LibreWolf on Fedora, with Ungoogled Chromium, Brave, Vivaldi and Firefox on Ubuntu 24.04,
    # with all five on Ubuntu 26.04, with Ungoogled Chromium and Firefox on Debian 13, and with
    # Ungoogled Chromium, Brave and Firefox on Linux Mint 22.
    ungoogled-chromium)
      if [[ $PKG == dnf || $UBUNTU_REL == 24.04 || $UBUNTU_REL == 26.04 || $DEBIAN_TESTED == 1 || $MINT_TESTED == 1 ]]; then echo ""; else echo untested; fi ;;
    vivaldi-flatpak)
      if [[ $PKG == dnf || $UBUNTU_REL == 24.04 || $UBUNTU_REL == 26.04 ]]; then echo ""; else echo untested; fi ;;
    firefox-flatpak)
      if [[ $UBUNTU_REL == 24.04 || $UBUNTU_REL == 26.04 || $DEBIAN_TESTED == 1 || $MINT_TESTED == 1 ]]; then echo ""; else echo untested; fi ;;
    brave-flatpak)
      if [[ $UBUNTU_REL == 24.04 || $UBUNTU_REL == 26.04 || $MINT_TESTED == 1 ]]; then echo ""; else echo untested; fi ;;
    # LibreWolf works on Fedora and Ubuntu 26.04 but not on Ubuntu 24.04 or Linux Mint 22 (which
    # is built on 24.04); the cause isn't known yet.
    librewolf-flatpak)
      if [[ $PKG == dnf || $UBUNTU_REL == 26.04 ]]; then echo ""
      elif [[ $UBUNTU_REL == 24.04 || $MINT_TESTED == 1 ]]; then echo broken
      else echo untested; fi ;;
    *) echo untested ;;
  esac
}
status_note() {
  case "$1" in
    untested) echo "untested" ;;
    broken) echo "doesn't work on this system yet" ;;
  esac
}
B_IDS=(); B_LABELS=(); B_PROCS=(); B_STATUS=()
add_browser() { B_IDS+=("$1"); B_LABELS+=("$2"); B_PROCS+=("$3"); B_STATUS+=("$(browser_status "$1")"); }
NOT_SUPPORTED=()   # installed browsers this script can't configure (yet)
has_snap()    { command -v snap &>/dev/null && snap list "$1" &>/dev/null; }
FIREFOX_PROC='^[^ ]*/firefox(-esr|-bin)?( |$)'

# Ubuntu's firefox/chromium debs are stubs that install the snap, so look for the real binaries.
# Debian's default is Firefox ESR, which uses the same profiles (~/.mozilla/firefox).
for f in /usr/lib64/firefox/firefox /usr/lib/firefox/firefox /opt/firefox/firefox /usr/lib/firefox-esr/firefox-esr; do
  if [[ -x $f ]]; then add_browser firefox "Firefox" "$FIREFOX_PROC"; break; fi
done
if has_snap firefox; then add_browser firefox-snap "Firefox (Snap)" "$FIREFOX_PROC"; fi
# Native Chromium-based browsers all read ~/.pki/nssdb, so they are configured together.
CHROME_NAMES=(); CHROME_PROCS=()
for entry in "Google Chrome:/opt/google/chrome/chrome" "Chromium:/usr/lib64/chromium-browser/chromium-browser" \
             "Chromium:/usr/lib/chromium/chromium" "Microsoft Edge:/opt/microsoft/msedge/msedge" \
             "Brave:/opt/brave.com/brave/brave" "Vivaldi:/opt/vivaldi/vivaldi-bin"; do
  [[ -x ${entry#*:} ]] || continue
  CHROME_NAMES+=("${entry%%:*}"); CHROME_PROCS+=("^${entry#*:}( |$)")
done
if [[ ${#CHROME_NAMES[@]} -gt 0 ]]; then
  add_browser chrome "$(join ", " "${CHROME_NAMES[@]}")" "$(join "|" "${CHROME_PROCS[@]}")"
fi
# Flatpak browsers (system or user installs) reach the card through the bridge in step 5.
declare -A FP_APP=() FP_KIND=() FP_NAME=()
FLATPAK_APPS=""
if command -v flatpak &>/dev/null; then
  FLATPAK_APPS=" $(as_user flatpak list --app --columns=application 2>/dev/null | tr '\n' ' ' || true) "
fi
for entry in "${FLATPAK_BROWSERS[@]}"; do
  IFS='|' read -r id app label kind <<<"$entry"
  [[ $FLATPAK_APPS == *" $app "* ]] || continue
  add_browser "$id" "$label (Flatpak)" "$app"
  FP_APP[$id]=$app; FP_KIND[$id]=$kind; FP_NAME[$id]=$label
done
# Chromium's snap brings its own OpenSC, but its base snap lacks part of pcsc-lite (step 4).
if has_snap chromium; then add_browser chromium-snap "Chromium (Snap)" '^/snap/chromium/[^ ]*/chrome( |$)'; fi

# ---- which detected browsers are already set up (by an earlier run of this script)
# The host's own p11-kit client, if it has one (Debian/Ubuntu; Fedora doesn't ship it): Flatpak
# browsers get a copy of it (step 5).
HOST_P11_CLIENT=""
for p in /usr/lib/x86_64-linux-gnu/pkcs11/p11-kit-client.so /usr/lib64/pkcs11/p11-kit-client.so; do
  [[ -f $p ]] && { HOST_P11_CLIENT=$p; break; }
done
BRIDGE_ENV="CAC_P11_BRIDGE_ADDRESS"   # the variable a Flatpak wrapper sets (see step 5)
HOME_ACCESS_RE=';(home|host)(:rw|:create)?;'
# The Chromium snap's HOME is the folder of its installed revision, ~/snap/chromium/<revision>.
# (~/snap/chromium/current is a link to it that snapd creates on the first start, so it may not
# exist yet; never create it as a folder.)
SNAP_CHROMIUM_REV=$(readlink /snap/chromium/current 2>/dev/null || true)
SNAP_CHROMIUM_DB="$TARGET_HOME/snap/chromium/${SNAP_CHROMIUM_REV:-current}/.pki/nssdb"
SNAP_CHROMIUM_PCSC="$TARGET_HOME/snap/chromium/common/libpcsclite_real.so.1"
SNAP_OPENSC=/usr/lib/x86_64-linux-gnu/opensc-pkcs11.so   # where the Chromium snap maps its OpenSC
# Python that prints "SLOTS TOKENS" for the PKCS#11 module in argv[1]: its slots (one per card
# reader, card or not) and how many of them hold a card.
SLOT_TEST_PY='
import ctypes as c, sys
l = c.CDLL(sys.argv[1])
fl = c.POINTER(c.c_void_p)(); l.C_GetFunctionList(c.byref(fl))
P = c.cast(fl, c.POINTER(c.c_void_p))
f = lambda i, *a: c.CFUNCTYPE(c.c_ulong, *a)(P[1 + i])
f(0, c.c_void_p)(None)
gsl = f(4, c.c_ubyte, c.c_void_p, c.c_void_p); slots = c.c_ulong(0); tokens = c.c_ulong(0)
gsl(0, None, c.byref(slots)); gsl(1, None, c.byref(tokens))
print(slots.value, tokens.value)'
# self_test_result NAME WHERE "SLOTS TOKENS": reports a self-test. A reader shows up as a slot even
# without a card, so the path to the card can be checked with no CAC inserted. (OpenSC also lists
# an empty slot when there's no reader at all, hence the check against what step 2 found.)
self_test_result() {
  local name=$1 where=$2 slots tokens
  read -r slots tokens <<<"$3"
  if [[ ! $slots =~ ^[0-9]+$ || ! $tokens =~ ^[0-9]+$ ]]; then
    warn "Self-test could not run for $name (it is still configured)"
  elif (( tokens > 0 )); then
    ok "Self-test: CAC visible $where"
  elif [[ $HAVE_READER == 0 ]]; then
    ok "Self-test skipped for $name: no card reader plugged in"
  elif (( slots > 0 )); then
    ok "Self-test: card reader reachable $where (no CAC inserted)"
  else
    warn "Self-test: $name can't reach the card reader (try again after logging out and back in)"
  fi
}

# The NSS DB a Chromium-based Flatpak uses: ~/.pki/nssdb as the sandbox sees it, which is the real
# one if the app can see your home directory, otherwise a per-app one.
fp_nssdb() {
  local perms fs
  perms=$(as_user flatpak info --show-permissions "$1" 2>/dev/null || true)
  fs=$(sed -n 's/^filesystems=//p' <<<"$perms")
  if [[ ";$fs" =~ $HOME_ACCESS_RE ]]; then echo "$TARGET_HOME/.pki/nssdb"
  else echo "$TARGET_HOME/.var/app/$1/.pki/nssdb"; fi
}
# nss_has_dod DIR: the NSS DB in DIR holds the DoD roots. Checked on a copy without its module
# list, so no card module (and no card reader) is woken up.
nss_has_dod() {
  local tmp rc=1
  [[ -f $1/cert9.db ]] && command -v certutil &>/dev/null || return 1
  tmp=$(mktemp -d)
  cp "$1/cert9.db" "$tmp/"
  cp "$1/key4.db" "$tmp/" 2>/dev/null || true
  if certutil -L -d "sql:$tmp" 2>/dev/null | grep -q "DoD Root CA"; then rc=0; fi
  rm -rf "$tmp"
  return $rc
}
# profiles_have_dod DIR...: every Firefox profile under the DIRs has the DoD roots and lists MODULE
# (when MODULE isn't empty); at least one profile must exist. MODULE comes first.
profiles_have_dod() {
  local module=$1 db found=1; shift
  while IFS= read -r db; do
    nss_has_dod "$(dirname "$db")" || return 1
    if [[ -n $module ]]; then grep -qs "^library=$module$" "$(dirname "$db")/pkcs11.txt" || return 1; fi
    found=0
  done < <(find "$@" -maxdepth 6 -name cert9.db -not -path '*/.pki/*' 2>/dev/null)
  return $found
}
snap_plug_connected() { snap connections "$1" 2>/dev/null | grep -qE "^[a-z-]+ +$1:$2 +:"; }
browser_set_up() {
  local id=$1 app dir db
  case "$id" in
    firefox|firefox-snap)
      grep -qs "$CERT_DIR/roots" /etc/firefox/policies/policies.json || return 1
      if [[ $id == firefox-snap ]]; then
        snap_plug_connected firefox pcscd || return 1
        dir=$TARGET_HOME/snap/firefox/common/.mozilla/firefox
        [[ -d $dir ]] || return 0
        profiles_have_dod "" "$dir"
      else
        for dir in "$TARGET_HOME/.mozilla/firefox" "$TARGET_HOME/.config/mozilla/firefox"; do
          [[ -d $dir ]] && { profiles_have_dod "" "$dir" || return 1; }
        done
        return 0
      fi ;;
    chrome)
      nss_has_dod "$TARGET_HOME/.pki/nssdb" || return 1
      grep -qs "opensc-pkcs11.so" "$TARGET_HOME/.pki/nssdb/pkcs11.txt" \
        || { grep -qs 'p11-kit-proxy' /etc/crypto-policies/back-ends/nss.config; } ;;
    chromium-snap)
      snap_plug_connected chromium pcscd && [[ -f $SNAP_CHROMIUM_PCSC ]] \
        && nss_has_dod "$SNAP_CHROMIUM_DB" && grep -qs "^library=$SNAP_OPENSC$" "$SNAP_CHROMIUM_DB/pkcs11.txt" \
        && grep -qs "LIBPCSCLITE_DELEGATE" "$TARGET_HOME/.local/share/applications/chromium_chromium.desktop" ;;
    *)
      app=${FP_APP[$id]:-}; [[ -n $app ]] || return 1
      dir=$TARGET_HOME/.var/app/$app
      grep -qs "^export $BRIDGE_ENV=" "$dir/cac-launch.sh" || return 1
      # A client copy from before its default address pointed at the bridge needs redoing.
      grep -qas "%s/cac-p11/opensc" "$dir/cac-p11-client.so" || return 1
      grep -qs "cac-launch.sh" "$TARGET_HOME/.local/share/applications/$app.desktop" || return 1
      if [[ ${FP_KIND[$id]} == chromium ]]; then
        db=$(fp_nssdb "$app")
        nss_has_dod "$db" || return 1
        grep -qs "cac-p11-client.so" "$db/pkcs11.txt"
      else
        profiles_have_dod "$dir/cac-p11-client.so" "$dir"
      fi ;;
  esac
}
B_SETUP=()   # 1 if that browser is already set up
for i in "${!B_IDS[@]}"; do
  if browser_set_up "${B_IDS[i]}"; then B_SETUP[i]=1; else B_SETUP[i]=0; fi
done

if [[ ${#B_IDS[@]} -gt 0 ]]; then ok "Browsers: $(join ", " "${B_LABELS[@]}")"; fi
if [[ ${#NOT_SUPPORTED[@]} -gt 0 ]]; then warn "Not supported yet: $(join ", " "${NOT_SUPPORTED[@]}")"; fi

# ---- choices
if [[ -z $WANT_AVD ]]; then
  if [[ $AVD_AVAILABLE == 0 ]]; then
    warn "Army AVD launcher unavailable here (no FreeRDP 3 / PyQt6 WebEngine packages); CAC only."
    WANT_AVD=0
  elif [[ $INTERACTIVE == 1 ]]; then
    menu 0 "What do you want to set up?" \
      "CAC only: smart card, DoD certificates and browsers" \
      "CAC + Army AVD: also install the Army AVD desktop launcher" \
      "Army AVD only: the launcher and what its CAC sign-in needs, no browsers"
    case $MENU_CHOICE in
      0) WANT_AVD=0 ;;
      1) WANT_AVD=1 ;;
      2) WANT_AVD=1; AVD_ONLY=1 ;;
    esac
  else
    WANT_AVD=1
  fi
fi
if [[ $WANT_AVD == 1 && $AVD_AVAILABLE == 0 ]]; then
  die "Army AVD needs FreeRDP 3 and PyQt6 WebEngine, which this system's package sources don't offer. Use --no-avd."
fi
# Army AVD only: no browsers. Its sign-in window uses ~/.pki/nssdb, which step 4 sets up for AVD.
if [[ $AVD_ONLY == 1 ]]; then
  if [[ -n $BROWSER_ARG && $BROWSER_ARG != none ]]; then die "--avd-only sets up no browsers; drop --browsers."; fi
  BROWSER_ARG=none
fi

declare -A SEL=()
# Selects every browser except those known not to work here (they can still be named explicitly).
select_all_working() {
  local i
  for i in "${!B_IDS[@]}"; do
    if [[ ${B_STATUS[i]} == broken ]]; then
      warn "Skipping ${B_LABELS[i]}: $(status_note broken) (name it with --browsers to try anyway)."
    else
      SEL[${B_IDS[i]}]=1
    fi
  done
}
if [[ -n $BROWSER_ARG ]]; then
  case "$BROWSER_ARG" in
    all) select_all_working ;;
    new)
      select_all_working
      for i in "${!B_IDS[@]}"; do
        if [[ ${B_SETUP[i]} == 1 ]]; then unset "SEL[${B_IDS[i]}]"; fi
      done ;;
    none) ;;
    *)
      IFS=, read -ra wanted <<<"$BROWSER_ARG"
      for id in "${wanted[@]}"; do
        [[ " firefox firefox-snap chrome chromium-snap ${FLATPAK_BROWSERS[*]%%|*} " == *" $id "* ]] \
          || die "Unknown browser '$id' (see --help)"
        [[ " ${B_IDS[*]} " == *" $id "* ]] || die "Browser '$id' isn't installed for $TARGET_USER."
        SEL[$id]=1
      done ;;
  esac
elif [[ ${#B_IDS[@]} -eq 0 ]]; then
  warn "No supported browsers found; only the smart card middleware and certificates will be set up."
elif [[ $INTERACTIVE == 1 ]]; then
  # Browsers that are already set up start unticked, so a re-run just adds the new ones.
  MENU_ON=(); items=()
  for i in "${!B_IDS[@]}"; do
    note=$(status_note "${B_STATUS[i]}")
    if [[ ${B_SETUP[i]} == 1 ]]; then note="set up${note:+; $note}"; fi
    items+=("${B_LABELS[i]}${note:+  ($note)}")
    if [[ ${B_STATUS[i]} == broken || ${B_SETUP[i]} == 1 ]]; then MENU_ON[i]=0; else MENU_ON[i]=1; fi
  done
  menu 1 "Which browsers should use your CAC? (tick set-up ones to redo them)" "${items[@]}"
  for i in "${!B_IDS[@]}"; do
    if [[ ${MENU_ON[i]} == 1 ]]; then SEL[${B_IDS[i]}]=1; fi
  done
else
  select_all_working
fi
sel() { [[ ${SEL[$1]:-0} == 1 ]]; }

CHOSEN=(); SEL_FLATPAKS=(); CAVEATS=(); KEPT=()
for i in "${!B_IDS[@]}"; do
  if ! sel "${B_IDS[i]}" && [[ ${B_SETUP[i]} == 1 ]]; then KEPT+=("${B_LABELS[i]}"); fi
  if sel "${B_IDS[i]}"; then
    CHOSEN+=("${B_LABELS[i]}")
    if [[ -n ${B_STATUS[i]} ]]; then CAVEATS+=("${B_LABELS[i]}: $(status_note "${B_STATUS[i]}")"); fi
    if [[ -n ${FP_APP[${B_IDS[i]}]:-} ]]; then SEL_FLATPAKS+=("${B_IDS[i]}"); fi
  fi
done
echo
info "Ready to set up"
printf '    System:    %s (%s), user %s\n' "$OS_NAME" "$ARCH" "$TARGET_USER"
if [[ $AVD_ONLY == 1 ]]; then printf '    Setup:     Army AVD only (smart card, DoD certificates and the launcher)\n'
elif [[ $WANT_AVD == 1 ]]; then printf '    Setup:     CAC + Army AVD launcher\n'
else printf '    Setup:     CAC only\n'; fi
if [[ ${#CHOSEN[@]} -gt 0 ]]; then
  printf '    Browsers:  %s\n' "$(join ", " "${CHOSEN[@]}")"
  for c in "${CAVEATS[@]}"; do printf '    %s!%s          %s\n' "$c_warn" "$c_off" "$c"; done
else
  printf '    Browsers:  none\n'
fi
if [[ ${#KEPT[@]} -gt 0 ]]; then printf '    Unchanged: %s (already set up)\n' "$(join ", " "${KEPT[@]}")"; fi
if [[ $INTERACTIVE == 1 && $ASSUME_YES == 0 ]]; then
  confirm "Continue?" y || die "Cancelled; nothing was changed."
fi

# ---------------------------------------------------------------- browsers must be closed
# Firefox reads its policy and security devices only at startup, and a running Chromium
# rewrites its NSS module list on exit, undoing the changes below.
running_browsers() {
  local i
  for i in "${!B_IDS[@]}"; do
    if sel "${B_IDS[i]}" && pgrep -u "$TARGET_USER" -f "${B_PROCS[i]}" >/dev/null; then
      echo "${B_LABELS[i]}"
    fi
  done
}
if command -v pgrep &>/dev/null; then
  BROWSERS=$(running_browsers)
  while [[ -n "$BROWSERS" ]]; do
    warn "Close these browsers before continuing (all windows): ${BROWSERS//$'\n'/, }"
    [[ $INTERACTIVE == 1 ]] || die "Browsers are running; close them and run the script again."
    read -rp "    Press Enter once they are closed... " _
    BROWSERS=$(running_browsers)
  done
elif [[ ${#CHOSEN[@]} -gt 0 ]]; then
  warn "Can't check for running browsers (no pgrep); make sure they are closed."
fi

WORK=$(mktemp -d)

# ================================================================ 1. packages
PKGS=("${BASE_PKGS[@]}")
if [[ $WANT_AVD == 1 ]]; then PKGS+=("${AVD_PKGS[@]}"); fi
info "Installing packages: ${PKGS[*]}"
if [[ $PKG == dnf ]]; then
  dnf install -y "${PKGS[@]}" || die "Package installation failed."
  if rpm -q coolkey &>/dev/null; then
    warn "coolkey is installed and can conflict with OpenSC for CAC cards; consider: sudo dnf remove coolkey"
  fi
else
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${PKGS[@]}" || die "Package installation failed."
fi

OPENSC_LIB=""
# On Debian/Ubuntu the unprefixed path comes first: it is the path Ubuntu documents for snap Firefox.
for p in /usr/lib64/pkcs11/opensc-pkcs11.so /usr/lib/x86_64-linux-gnu/opensc-pkcs11.so \
         /usr/lib/x86_64-linux-gnu/pkcs11/opensc-pkcs11.so /usr/lib/pkcs11/opensc-pkcs11.so; do
  [[ -e "$p" ]] && { OPENSC_LIB="$p"; break; }
done
[[ -n "$OPENSC_LIB" ]] || die "opensc-pkcs11.so not found after install"

P11_REMOTE=""
for p in /usr/libexec/p11-kit/p11-kit-remote /usr/lib/x86_64-linux-gnu/p11-kit/p11-kit-remote \
         /usr/lib/p11-kit/p11-kit-remote; do
  [[ -x "$p" ]] && { P11_REMOTE="$p"; break; }
done

# Check that everything the rest of the script calls is really there.
missing=()
for c in pcscd opensc-tool pkcs11-tool certutil modutil p11-kit openssl unzip curl python3 lsusb pgrep; do
  command -v "$c" &>/dev/null || missing+=("$c")
done
if [[ ${#SEL_FLATPAKS[@]} -gt 0 ]]; then
  [[ -n $P11_REMOTE ]] || missing+=("p11-kit-remote")
  command -v flatpak &>/dev/null || missing+=("flatpak")
fi
if [[ $WANT_AVD == 1 ]]; then
  FREERDP_BIN=$(command -v xfreerdp3 || command -v xfreerdp || true)
  [[ -n $FREERDP_BIN ]] || missing+=("xfreerdp3/xfreerdp")
  python3 -I -c 'import PyQt6.QtWebEngineWidgets' 2>/dev/null || missing+=("PyQt6 WebEngine")
fi
[[ ${#missing[@]} -eq 0 ]] || die "Still missing after installing packages: $(join ", " "${missing[@]}")"
if [[ $WANT_AVD == 1 ]]; then
  buildconfig=$("$FREERDP_BIN" /buildconfig 2>&1 || true)
  [[ $buildconfig == *WITH_AAD=ON* ]] \
    || die "$FREERDP_BIN was built without Azure AD support, which Army AVD needs. Re-run and choose CAC only."
  # Army AVD is in Azure Government, which needs FreeRDP's avd-scope and avd-access options (listed
  # in its /azure help). Debian 13's FreeRDP (3.15) predates them; Debian's backports have a newer
  # one (3.32), so take FreeRDP from there.
  freerdp_gov() { local h; h=$("$FREERDP_BIN" /help 2>&1 || true); [[ $h == *avd-scope* ]]; }
  if ! freerdp_gov && [[ $OS_ID == debian && -n $OS_CODENAME ]]; then
    bpo="$OS_CODENAME-backports"
    if [[ $(apt-cache policy 2>/dev/null) != *" $bpo/"* ]]; then
      cat > /etc/apt/sources.list.d/debian-backports.sources <<EOF
# Added by cac_setup.sh: Debian's backports, for a FreeRDP new enough for Army AVD.
Types: deb
URIs: http://deb.debian.org/debian
Suites: $bpo
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
      apt-get update -qq || warn "apt-get update failed after adding $bpo"
    fi
    info "Installing FreeRDP from $bpo (Debian's own is too old for Army AVD)"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -t "$bpo" freerdp3-x11 \
      || warn "Installing FreeRDP from $bpo failed"
  fi
  freerdp_gov || die "$("$FREERDP_BIN" /version 2>&1 | head -1) is too old for Army AVD in Azure Government (its /azure option lacks avd-scope). Install a newer FreeRDP 3, or re-run and choose CAC only."
fi
ok "All dependencies installed"

# Fedora/RHEL crypto-policies make every NSS app (Firefox included) load p11-kit-proxy, which
# already includes OpenSC. Adding opensc-pkcs11.so again makes NSS load it twice and fail with
# "Unknown PKCS #11 error", so only add it explicitly where the proxy doesn't cover it.
NSS_HAS_P11_PROXY=0
if grep -qs 'p11-kit-proxy' /etc/crypto-policies/back-ends/nss.config \
   && p11-kit list-modules 2>/dev/null | grep -q '^module: opensc'; then
  NSS_HAS_P11_PROXY=1
fi

# ================================================================ 2. reader
info "Starting pcscd and checking for a smart card reader"
# pcscd's polkit policy only allows processes in the active desktop session. The browser bridge
# runs as a systemd user service and this script runs via sudo/runuser, so neither qualifies;
# allow the target user's own processes to use the reader. Only that bridge needs it.
if [[ ${#SEL_FLATPAKS[@]} -gt 0 && -d /etc/polkit-1/rules.d ]]; then
  cat > /etc/polkit-1/rules.d/90-cac-pcsc.rules <<EOF
// Installed by cac_setup.sh: let $TARGET_USER use the smart card reader outside the active session.
polkit.addRule(function(action, subject) {
    if ((action.id == "org.debian.pcsc-lite.access_pcsc" ||
         action.id == "org.debian.pcsc-lite.access_card") &&
        subject.user == "$TARGET_USER") {
        return polkit.Result.YES;
    }
});
EOF
  chmod 644 /etc/polkit-1/rules.d/90-cac-pcsc.rules
  ok "polkit rule: $TARGET_USER may access the card from any of their processes"
fi
# ---- card readers. The generic CCID driver from step 1 covers nearly every CAC reader: its list
# has several hundred (SCM/Identiv, HID Omnikey, Thales/Gemalto, ACS ACR39U, Cherry, IOGEAR...).
# Readers are found by their smart card interface, not by name; older ACS readers (ACR38 and
# others) show a vendor-specific interface instead and need ACS's own driver.
CCID_PLIST=""
for p in /usr/lib64/pcsc/drivers/ifd-ccid.bundle/Contents/Info.plist /usr/lib/pcsc/drivers/ifd-ccid.bundle/Contents/Info.plist; do
  [[ -f $p ]] && { CCID_PLIST=$p; break; }
done
usb_readers() {   # VID:PID of each USB smart card reader (and each ACS device)
  local dev intf vid
  for dev in /sys/bus/usb/devices/*; do
    [[ -f $dev/idVendor ]] || continue
    vid=$(cat "$dev/idVendor")
    for intf in "$dev"/*:*; do
      if [[ $(cat "$intf/bInterfaceClass" 2>/dev/null) == 0b || $vid == 072f ]]; then
        echo "$vid:$(cat "$dev/idProduct")"; break
      fi
    done
  done | sort -u
}
ccid_supports() {   # ccid_supports VID:PID: the CCID driver lists this reader
  [[ -n $CCID_PLIST ]] || return 1
  python3 -I - "$CCID_PLIST" "$1" <<'EOF'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
pairs = {f"{v[2:]}:{p[2:]}".lower() for v, p in zip(d["ifdVendorID"], d["ifdProductID"])}
sys.exit(0 if sys.argv[2].lower() in pairs else 1)
EOF
}
for id in $(usb_readers); do
  rname=$(lsusb -d "$id" 2>/dev/null | cut -d' ' -f7- | head -1 || true)
  if ccid_supports "$id"; then
    ok "Card reader: ${rname:-$id} (supported by the CCID driver)"
  elif [[ ${id%:*} == 072f ]]; then
    if [[ $PKG == dnf ]]; then acs_pkg=pcsc-lite-acsccid; else acs_pkg=libacsccid1; fi
    info "Installing ACS's driver ($acs_pkg) for ${rname:-$id}"
    if [[ $PKG == dnf ]]; then dnf install -y -q "$acs_pkg" >/dev/null 2>&1; else apt-get install -y -qq "$acs_pkg" >/dev/null 2>&1; fi \
      && ok "Card reader: ${rname:-$id} (ACS driver installed)" \
      || warn "Couldn't install $acs_pkg; ${rname:-$id} may not work until it's installed."
  else
    warn "Card reader ${rname:-$id} isn't on the CCID driver's list. It may still work as a generic"
    warn "CCID reader; if pcscd doesn't see it below, it needs its maker's Linux driver."
  fi
done

# Newer pcsc-lite (Ubuntu 26.04) runs pcscd as its own user, which may open a reader only once the
# CCID driver's udev rule has given it the reader. That rule applies when a reader is plugged in,
# so one plugged in before the driver was installed keeps root-only access ("LIBUSB_ERROR_ACCESS").
# Re-apply the rules to readers already plugged in (devices with a smart card interface only).
udevadm control --reload >/dev/null 2>&1 || true
udevadm trigger --action=add --subsystem-match=usb --property-match='ID_USB_INTERFACES=*:0b0000:*' \
  >/dev/null 2>&1 || true
udevadm settle >/dev/null 2>&1 || true
systemctl enable --now pcscd.socket >/dev/null 2>&1 || systemctl enable --now pcscd >/dev/null 2>&1 || true
systemctl restart pcscd.service >/dev/null 2>&1 || true
sleep 2

# Neither a reader nor a card is needed to set things up; they only make the self-tests complete.
HAVE_READER=0; HAVE_CARD=0
READERS=$(opensc-tool -l 2>/dev/null | grep -E '^[0-9]+' || true)
if [[ -z "$READERS" ]]; then
  warn "No card reader visible to pcscd. Setup continues; plug the reader in before you sign in."
  warn "(Nearly all CAC readers use the generic CCID driver installed above.)"
else
  HAVE_READER=1
  ok "pcscd sees: $(echo "$READERS" | head -1 | sed -E 's/^[0-9]+ +(Yes|No) +//')"
  if pkcs11-tool --module "$OPENSC_LIB" -L 2>/dev/null | grep -q 'token label'; then
    HAVE_CARD=1
    ok "CAC detected: $(pkcs11-tool --module "$OPENSC_LIB" -L 2>/dev/null | sed -n 's/.*token label *: //p' | head -1)"
  else
    ok "No CAC inserted. That's fine: setup doesn't need it, and the CAC works once you insert it."
  fi
fi

# ================================================================ 3. DoD certs
info "Downloading DoD PKI certificate bundle"
curl -fsSL --retry 3 -o "$WORK/dod.zip" "$DOD_ZIP_URL" || die "Download failed: $DOD_ZIP_URL"
mkdir "$WORK/zip"
unzip -q "$WORK/dod.zip" -d "$WORK/zip"
BUNDLE_DIR=$(dirname "$(find "$WORK/zip" -name '*_DoD.der.p7b' | head -1)")
P7B=$(find "$BUNDLE_DIR" -maxdepth 1 -name 'Certificates_PKCS7_*_DoD.der.p7b' | head -1)
MANIFEST=$(find "$BUNDLE_DIR" -maxdepth 1 -name '*.sha256' | head -1)
CHAIN="$BUNDLE_DIR/DoD_PKE_CA_chain.pem"
[[ -f "$P7B" && -f "$MANIFEST" && -f "$CHAIN" ]] || die "Unexpected bundle layout"
ok "Bundle: $(basename "$P7B")"

info "Verifying bundle signature against pinned DoD Root CA fingerprints"
# Split the signer chain; only certificates matching a pinned root become trust anchors.
awk -v d="$WORK" '/BEGIN CERT/{n++} n{print > (d "/chain" n ".pem")}' "$CHAIN"
: > "$WORK/pinned.pem"
for f in "$WORK"/chain*.pem; do
  fp=$(openssl x509 -in "$f" -noout -fingerprint -sha256 | cut -d= -f2)
  for pin in "${PINNED_ROOTS[@]}"; do
    [[ "$fp" == "$pin" ]] && cat "$f" >> "$WORK/pinned.pem"
  done
done
[[ -s "$WORK/pinned.pem" ]] || die "Bundle signer does not chain to a known DoD Root CA - refusing to install"
# DISA signs the manifest with SHA-1, which Fedora/RHEL crypto policies reject; allow it for this
# one command only (the manifest itself carries SHA-256 hashes).
cat > "$WORK/sha1.cnf" <<'EOF'
openssl_conf = openssl_init
[openssl_init]
alg_section = evp_properties
[evp_properties]
rh-allow-sha1-signatures = yes
EOF
OPENSSL_CONF="$WORK/sha1.cnf" openssl cms -verify -inform DER -in "$MANIFEST" -CAfile "$WORK/pinned.pem" -certfile "$CHAIN" \
  -purpose any -out "$WORK/manifest.txt" 2>"$WORK/cms.err" \
  || die "Manifest signature verification failed: $(cat "$WORK/cms.err")"
expected=$(tr -d '\r' < "$WORK/manifest.txt" | awk -v f="$(basename "$P7B")" '$2==f{print $1}')
actual=$(sha256sum "$P7B" | cut -d' ' -f1)
[[ -n "$expected" && "$expected" == "$actual" ]] || die "Bundle hash mismatch - refusing to install"
ok "Signature and SHA-256 verified"

info "Extracting certificates to $CERT_DIR"
rm -rf "$CERT_DIR"; mkdir -p "$CERT_DIR/roots" "$CERT_DIR/intermediates"
openssl pkcs7 -inform DER -in "$P7B" -print_certs -out "$WORK/all.pem"
awk -v d="$WORK" '/BEGIN CERT/{n++} n{print > (d "/cert" n ".pem")}' "$WORK/all.pem"
n_root=0; n_int=0
for f in "$WORK"/cert*.pem; do
  subj=$(openssl x509 -in "$f" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')
  iss=$(openssl x509 -in "$f" -noout -issuer -nameopt RFC2253 | sed 's/^issuer=//')
  cn=$(sed -n 's/^CN=\([^,]*\).*/\1/p' <<<"$subj")
  name=$(tr -c 'A-Za-z0-9_.-' '_' <<<"${cn:-cert}" | sed 's/_*$//')
  if [[ "$subj" == "$iss" ]]; then
    openssl x509 -in "$f" -out "$CERT_DIR/roots/$name.pem"; n_root=$((n_root+1))
  else
    openssl x509 -in "$f" -out "$CERT_DIR/intermediates/$name.pem"; n_int=$((n_int+1))
  fi
done
cat "$CERT_DIR"/roots/*.pem "$CERT_DIR"/intermediates/*.pem > "$CERT_DIR/DoD_PKI_all.pem"
chmod -R a+rX "$CERT_DIR"
ok "$n_root root CAs, $n_int intermediate CAs"

info "Adding DoD Root CAs to the system trust store"
if [[ -d /etc/pki/ca-trust/source/anchors ]]; then
  rm -f /etc/pki/ca-trust/source/anchors/DoD_*.pem
  for f in "$CERT_DIR"/roots/*.pem; do cp "$f" "/etc/pki/ca-trust/source/anchors/$(basename "$f")"; done
  update-ca-trust extract
else
  mkdir -p /usr/local/share/ca-certificates/dod
  rm -f /usr/local/share/ca-certificates/dod/*.crt
  for f in "$CERT_DIR"/roots/*.pem; do cp "$f" "/usr/local/share/ca-certificates/dod/$(basename "${f%.pem}").crt"; done
  update-ca-certificates >/dev/null
fi
ok "System trust updated (also used by Fedora Firefox's built-in roots via p11-kit)"

# Public intermediates some sites omit; each must chain to a root in the system trust store.
SYSTEM_BUNDLE=""
for b in /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt; do
  [[ -f "$b" ]] && { SYSTEM_BUNDLE="$b"; break; }
done
mkdir -p "$CERT_DIR/extra"
for url in "${EXTRA_INTERMEDIATES[@]}"; do
  if curl -fsSL --retry 2 --max-time 20 -o "$WORK/extra.der" "$url" \
     && openssl x509 -inform DER -in "$WORK/extra.der" -out "$WORK/extra.pem" 2>/dev/null \
     && [[ -n "$SYSTEM_BUNDLE" ]] && openssl verify -CAfile "$SYSTEM_BUNDLE" "$WORK/extra.pem" >/dev/null 2>&1; then
    cn=$(openssl x509 -in "$WORK/extra.pem" -noout -subject -nameopt multiline | sed -n 's/^ *commonName *= //p')
    install -m 644 "$WORK/extra.pem" "$CERT_DIR/extra/$(tr -c 'A-Za-z0-9_.-' '_' <<<"$cn" | sed 's/_*$//').pem"
  else
    warn "Could not fetch or verify intermediate $url"
  fi
done

# Roots (trusted) and intermediates (untrusted, for path building) for the NSS DBs. Every certutil
# run loads the modules in the DB's pkcs11.txt, and OpenSC wakes the card reader, which can take
# seconds; so the certificates go into a module-free DB once and are merged into each DB in one run.
# The merge needs write access to that DB too, so it belongs to the user (and is removed on exit).
CERT_SRC_DB=$(as_user mktemp -d -t cac-certs.XXXXXX)
nss_cert_files() {   # prints "trust<TAB>nickname<TAB>file" for each certificate
  local f
  for f in "$CERT_DIR"/roots/*.pem; do
    [[ -f $f ]] && printf 'CT,C,C\t%s\t%s\n' "$(basename "${f%.pem}" | tr '_' ' ')" "$f"
  done
  for f in "$CERT_DIR"/intermediates/*.pem "$CERT_DIR"/extra/*.pem; do
    [[ -f $f ]] && printf ',,\t%s\t%s\n' "$(basename "${f%.pem}" | tr '_' ' ')" "$f"
  done
}
nss_import_certs() {
  local db="$1" trust nick f
  timeout 120 runuser -u "$TARGET_USER" -- \
    certutil --merge -d "sql:$db" --source-dir "sql:$CERT_SRC_DB" >/dev/null 2>&1 && return 0
  warn "Merging the certificates into $db failed; adding them one at a time (slower)"
  while IFS=$'\t' read -r trust nick f; do
    as_user certutil -A -d "sql:$db" -n "$nick" -t "$trust" -i "$f" || warn "certutil failed for $nick in $db"
  done < <(nss_cert_files)
}
nss_ensure_db() {
  local db="$1"
  as_user mkdir -p "$db"
  [[ -f "$db/cert9.db" ]] || as_user certutil -N -d "sql:$db" --empty-password
}

as_user certutil -N -d "sql:$CERT_SRC_DB" --empty-password
while IFS=$'\t' read -r trust nick f; do
  as_user certutil -A -d "sql:$CERT_SRC_DB" -n "$nick" -t "$trust" -i "$f" || warn "certutil failed for $nick"
done < <(nss_cert_files)

# ================================================================ 4. Firefox
if sel firefox || sel firefox-snap; then
  info "Configuring Firefox"
  # Enterprise policy (read by native and snap Firefox alike): installs the roots in every profile (including future ones) and, unless
  # p11-kit-proxy already provides it, loads OpenSC.
  mkdir -p /etc/firefox/policies
  POLICY=/etc/firefox/policies/policies.json
  python3 -I - "$POLICY" "$MODULE_NAME" "$OPENSC_LIB" "$CERT_DIR/roots" "$NSS_HAS_P11_PROXY" <<'PY'
import json, os, sys, glob
path, name, lib, rootdir, has_proxy = sys.argv[1:]
data = {}
if os.path.exists(path):
    with open(path) as fh:
        data = json.load(fh)
pol = data.setdefault("policies", {})
if has_proxy == "1":
    add = pol.get("SecurityDevices", {}).get("Add", {})
    add.pop(name, None)
    if not add:
        pol.get("SecurityDevices", {}).pop("Add", None)
    if not pol.get("SecurityDevices", True):
        pol.pop("SecurityDevices")
else:
    pol.setdefault("SecurityDevices", {}).setdefault("Add", {})[name] = lib
certs = pol.setdefault("Certificates", {})
inst = [p for p in certs.get("Install", []) if not p.startswith(rootdir)]
certs["Install"] = inst + sorted(glob.glob(os.path.join(rootdir, "*.pem")))
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
PY
  chmod 644 "$POLICY"
  # Debian's Firefox ESR looks for its policies under its own name.
  if [[ -d /usr/lib/firefox-esr ]]; then
    install -D -m 644 "$POLICY" /etc/firefox-esr/policies/policies.json
  fi
  if [[ $NSS_HAS_P11_PROXY -eq 1 ]]; then
    ok "Policy written: $POLICY (CAC provided by p11-kit-proxy via system crypto-policies)"
  else
    ok "Policy written: $POLICY (security device '$MODULE_NAME')"
  fi

  # Ubuntu's Firefox is a snap, which can't reach pcscd until this interface is connected.
  if sel firefox-snap; then
    snap connect firefox:pcscd 2>/dev/null && ok "Snap Firefox: pcscd interface connected" \
      || warn "Could not connect snap Firefox to pcscd; run: sudo snap connect firefox:pcscd"
  fi

  PROFILE_BASES=()
  if sel firefox; then PROFILE_BASES+=("$TARGET_HOME/.mozilla/firefox" "$TARGET_HOME/.config/mozilla/firefox"); fi
  if sel firefox-snap; then PROFILE_BASES+=("$TARGET_HOME/snap/firefox/common/.mozilla/firefox"); fi
  found=0
  for base in "${PROFILE_BASES[@]}"; do
    [[ -d "$base" ]] || continue
    while IFS= read -r db; do
      prof=$(dirname "$db")
      nss_import_certs "$prof"
      ok "DoD certs imported into profile $(basename "$prof")"
      found=1
    done < <(find "$base" -mindepth 2 -maxdepth 2 -name cert9.db)
  done
  [[ $found -eq 1 ]] || warn "No existing Firefox profiles found; the policy will cover new ones."
fi

# ---- host user NSS DB (~/.pki/nssdb): used by native Chrome/Chromium/Edge/Brave/Vivaldi and by
# the Army AVD sign-in window.
if sel chrome || [[ $WANT_AVD == 1 ]]; then
  info "Configuring the shared certificate store (~/.pki/nssdb)"
  nss_ensure_db "$TARGET_HOME/.pki/nssdb"
  if [[ $NSS_HAS_P11_PROXY -eq 1 ]]; then
    ok "CAC already available to NSS apps through p11-kit-proxy; no module to add"
  else
    modules=$(timeout 60 runuser -u "$TARGET_USER" -- modutil -dbdir "sql:$TARGET_HOME/.pki/nssdb" -list 2>/dev/null || true)
    if [[ $modules != *"$OPENSC_LIB"* ]]; then
      timeout 60 runuser -u "$TARGET_USER" -- modutil -dbdir "sql:$TARGET_HOME/.pki/nssdb" \
        -add "$MODULE_NAME" -libfile "$OPENSC_LIB" -force >/dev/null \
        || warn "Could not register OpenSC in ~/.pki/nssdb; continuing"
    fi
  fi
  nss_import_certs "$TARGET_HOME/.pki/nssdb"
  ok "~/.pki/nssdb configured"
fi

# ---- Chromium snap. It ships its own OpenSC (mapped to $SNAP_OPENSC), but its core26 base has only
# pcsc-lite's front library, which loads the real client from libpcsclite_real.so.1, and that file
# is missing. LIBPCSCLITE_DELEGATE points the front library at a copy of this system's client
# instead (matching this system's pcscd), kept in the snap's own folder, which the snap may read.
if sel chromium-snap; then
  info "Configuring Chromium (Snap)"
  snap connect chromium:pcscd 2>/dev/null && ok "Chromium snap: pcscd interface connected" \
    || warn "Could not connect snap Chromium to pcscd; run: sudo snap connect chromium:pcscd"
  pcsc_client=""
  for p in /usr/lib/x86_64-linux-gnu/libpcsclite_real.so.1 /usr/lib/x86_64-linux-gnu/libpcsclite.so.1; do
    # A front library (newer pcsc-lite) only delegates; we need the real client.
    if [[ -f $p ]] && ! grep -qa LIBPCSCLITE_DELEGATE "$p"; then pcsc_client=$p; break; fi
  done
  if [[ -z $pcsc_client ]]; then
    warn "Can't find this system's pcsc-lite client; Chromium (Snap) won't see the card."
  else
    as_user install -D -m 644 "$pcsc_client" "$SNAP_CHROMIUM_PCSC"
    ok "Chromium snap: pcsc-lite client copied ($(basename "$pcsc_client"))"
  fi
  # Its NSS DB is ~/.pki/nssdb with the snap's HOME (see SNAP_CHROMIUM_DB); snapd carries it over
  # to new revisions. An earlier version of this script could create ~/snap/chromium/current as a
  # folder when Chromium had never been started, which hides the real one from snapd: replace it
  # with the link snapd expects.
  cur="$TARGET_HOME/snap/chromium/current"
  if [[ -n $SNAP_CHROMIUM_REV && -d $cur && ! -L $cur ]]; then
    rm -rf "$cur"
    as_user ln -s "$SNAP_CHROMIUM_REV" "$cur"
    ok "Chromium snap: repaired ~/snap/chromium/current (a folder from an earlier run)"
  fi
  nss_ensure_db "$SNAP_CHROMIUM_DB"
  nss_import_certs "$SNAP_CHROMIUM_DB"
  if ! grep -qs "^library=$SNAP_OPENSC$" "$SNAP_CHROMIUM_DB/pkcs11.txt"; then
    timeout 60 runuser -u "$TARGET_USER" -- modutil -dbdir "sql:$SNAP_CHROMIUM_DB" \
      -add "$MODULE_NAME" -libfile "$SNAP_OPENSC" -force >/dev/null \
      || warn "Could not register OpenSC in Chromium's certificate store"
  fi
  ok "Chromium snap: DoD certificates and the CAC module installed"
  # Every start needs LIBPCSCLITE_DELEGATE: the menu entry sets it right away, the session-wide
  # setting covers other launches (terminal, links from other apps) after your next login.
  src=$TARGET_HOME/.local/share/applications/chromium_chromium.desktop
  [[ -f $src ]] || src=/var/lib/snapd/desktop/applications/chromium_chromium.desktop
  if [[ -f $src ]]; then
    # Read it all first: the source may be the very file being rewritten.
    entry=$(sed -E "s#^Exec=(env LIBPCSCLITE_DELEGATE=[^ ]+ )?/snap/bin/chromium#Exec=env LIBPCSCLITE_DELEGATE=$SNAP_CHROMIUM_PCSC /snap/bin/chromium#" "$src")
    as_user mkdir -p "$TARGET_HOME/.local/share/applications"
    printf '%s\n' "$entry" | as_user tee "$TARGET_HOME/.local/share/applications/chromium_chromium.desktop" >/dev/null
    ok "Menu launcher starts Chromium (Snap) with CAC support"
  else
    warn "No menu entry found for Chromium (Snap); start it with: LIBPCSCLITE_DELEGATE=$SNAP_CHROMIUM_PCSC chromium"
  fi
  as_user mkdir -p "$TARGET_HOME/.config/environment.d"
  printf 'LIBPCSCLITE_DELEGATE=%s\n' "$SNAP_CHROMIUM_PCSC" \
    | as_user tee "$TARGET_HOME/.config/environment.d/90-cac-pcsclite.conf" >/dev/null
  # Self-test inside the snap's confinement.
  TEST=$(as_user env XDG_RUNTIME_DIR="/run/user/$TARGET_UID" LIBPCSCLITE_DELEGATE="$SNAP_CHROMIUM_PCSC" \
           snap run --shell chromium -c 'python3 -I -c "$1" "$2"' sh "$SLOT_TEST_PY" "$SNAP_OPENSC" 2>/dev/null || echo err)
  self_test_result "Chromium (Snap)" "inside the Chromium snap" "$TEST"
fi

# ================================================================ 5. Flatpak browsers
if [[ ${#SEL_FLATPAKS[@]} -gt 0 ]]; then
  info "Setting up the CAC bridge for Flatpak browsers"
  # The Flatpak runtimes have no OpenSC. A socket-activated p11-kit-remote on the host serves
  # the CAC over PKCS#11 RPC, and the sandbox's p11-kit-client.so talks to it. A fresh process per
  # connection is needed because 'p11-kit server' forks after initializing OpenSC, which breaks the
  # PC/SC context and exposes no slots.
  # Chromium-based browsers use the runtime's NSS, whose built-in root module (libnssckbi.so)
  # loads p11-kit-client when P11_KIT_SERVER_ADDRESS is set, so pointing that at the bridge makes
  # the module serve the CAC. No separate NSS module is added: a second copy of the card runs its
  # own OpenSC process with its own login state, and the TLS signature then fails
  # (ERR_BAD_SSL_CLIENT_AUTH_CERT).
  # Firefox-based browsers bundle their own root module, so p11-kit-client.so is added to each
  # profile as a security device instead.
  # p11-kit's RPC breaks once you're logged in when the client is newer than the bridge, as on
  # Ubuntu 24.04 (p11-kit 0.25.3 vs the runtimes' newer one): key attributes come back garbled and
  # the bridge exits. Each browser therefore gets its own copy of a client that isn't newer than
  # the bridge, as its only CAC module: the host's (Debian/Ubuntu ship one, matching the bridge)
  # or else the app runtime's (Fedora ships none, and its bridge is newer than the runtimes'). The copy
  # reads CAC_P11_BRIDGE_ADDRESS instead of P11_KIT_SERVER_ADDRESS, so the runtime's root module,
  # which follows P11_KIT_SERVER_ADDRESS, stays a plain trust module and the card isn't served twice.
  # Its default address is changed to the bridge too, so it works however the browser is started.
  cat > /etc/systemd/user/cac-p11-bridge.socket <<'EOF'
[Unit]
Description=CAC PKCS#11 bridge for sandboxed browsers

[Socket]
ListenStream=%t/cac-p11/opensc
SocketMode=0600
DirectoryMode=0700
Accept=yes

[Install]
WantedBy=sockets.target
EOF
  cat > /etc/systemd/user/cac-p11-bridge@.service <<EOF
[Unit]
Description=CAC PKCS#11 bridge connection

[Service]
ExecStart=$P11_REMOTE $OPENSC_LIB
StandardInput=socket
StandardOutput=socket
StandardError=journal
EOF
  systemctl --global enable cac-p11-bridge.socket >/dev/null 2>&1
  if [[ -S "/run/user/$TARGET_UID/bus" ]]; then
    user_systemctl daemon-reload
    user_systemctl restart cac-p11-bridge.socket
    ok "Bridge socket active: /run/user/$TARGET_UID/cac-p11/opensc"
  else
    warn "You are not logged in graphically; the bridge starts at your next login."
  fi

  SANDBOX_LIB="/usr/lib/$(uname -m)-linux-gnu"   # runtime library directory inside the sandbox
  FP_FALLBACK=0   # 1 once a browser had to fall back to the runtime's client through the wrapper
  in_sandbox() {   # in_sandbox APP SCRIPT [ARGS...]: run a shell script inside APP's sandbox
    local app=$1; shift
    as_user env XDG_RUNTIME_DIR="/run/user/$TARGET_UID" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$TARGET_UID/bus" \
      flatpak run --command=sh "$app" -c "$@"
  }
  # Look for the host's p11-kit client again: on a first run, step 1 has only just installed it.
  HOST_P11_CLIENT=""
  for p in /usr/lib/x86_64-linux-gnu/pkcs11/p11-kit-client.so /usr/lib64/pkcs11/p11-kit-client.so; do
    [[ -f $p ]] && { HOST_P11_CLIENT=$p; break; }
  done
  # set_bridge_module PKCS11_TXT [LIBRARY]: drop every CAC bridge module (this script's old and
  # new ones) from an NSS DB's module list, then add LIBRARY as "CAC (bridge)" if given.
  set_bridge_module() {
    as_user python3 -I - "$@" <<'EOF'
import re, sys
path, lib = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "")
entries = [e for e in re.split(r"\n\s*\n", open(path).read()) if e.strip()]
entries = [e for e in entries if not re.search(r"^library=.*(p11-kit-client|cac-p11-client)\.so$", e, re.M)]
if lib:
    entries.append(f"library={lib}\nname=CAC (bridge)")
open(path, "w").write("\n\n".join(entries) + "\n")
EOF
  }
  as_user mkdir -p "$TARGET_HOME/.local/share/applications"
  for id in "${SEL_FLATPAKS[@]}"; do
    app=${FP_APP[$id]}; kind=${FP_KIND[$id]}; name=${FP_NAME[$id]}
    info "Configuring $name (Flatpak)"
    # The wrapper repoints the runtime's root module at the card. Firefox builds bundle their own
    # NSS and don't use it; one built against the runtime's NSS would lose its root certificates.
    if [[ $kind == firefox ]]; then
      bundled=$(in_sandbox "$app" 'find /app -name libnss3.so -print -quit' 2>/dev/null || echo err)
      if [[ -z $bundled ]]; then
        warn "$name uses the runtime's NSS, which the CAC bridge would break; skipping it."
        continue
      fi
    fi
    APPDIR="$TARGET_HOME/.var/app/$app"
    as_user mkdir -p "$APPDIR"
    as_user flatpak override --user --filesystem=xdg-run/cac-p11 "$app"

    # Flatpak strips P11_KIT_SERVER_ADDRESS from the environment, so a wrapper sets it inside the
    # sandbox and then runs the app's own command.
    meta=$(as_user flatpak info --show-metadata "$app" 2>/dev/null || true)
    cmd=$(sed -n 's/^command=//p' <<<"$meta" | head -1)
    if [[ -z $cmd ]]; then
      warn "Can't find how $app starts; skipping it."
      continue
    fi
    # The client the browser uses: an adjusted copy (see above) of the host's own p11-kit client
    # where there is one (Debian/Ubuntu: matches the bridge), otherwise of the app's own runtime
    # client (Fedora: the runtimes' client is older than the bridge, which works). If that fails,
    # the runtime's client through P11_KIT_SERVER_ADDRESS, which needs the menu launcher.
    BRIDGE_CLIENT=""
    rm -f "$APPDIR/cac-p11-client.so"
    src=$HOST_P11_CLIENT
    if [[ -z $src ]]; then
      src="$APPDIR/.runtime-p11-kit-client.so"
      in_sandbox "$app" 'cat "$1" > "$2"' sh "$SANDBOX_LIB/pkcs11/p11-kit-client.so" "$src" >/dev/null 2>&1 \
        || rm -f "$src"
    fi
    if [[ -s $src ]]; then
      as_user python3 -I - "$src" "$APPDIR/cac-p11-client.so" <<'EOF' || true
import sys
data = open(sys.argv[1], "rb").read()
# Its own address variable, and a default address (used when the browser wasn't started through
# the wrapper, e.g. from a terminal or a link in another app) that is the bridge rather than
# Flatpak's own p11-kit service. Same lengths, so the library's layout doesn't change.
pairs = [(b"P11_KIT_SERVER_ADDRESS\0", b"CAC_P11_BRIDGE_ADDRESS\0"),
         (b"%s/p11-kit/pkcs11\0", b"%s/cac-p11/opensc\0")]
if all(data.count(old) == 1 for old, _ in pairs):
    for old, new in pairs:
        data = data.replace(old, new)
    open(sys.argv[2], "wb").write(data)
EOF
    fi
    rm -f "$APPDIR/.runtime-p11-kit-client.so"
    if [[ -f $APPDIR/cac-p11-client.so ]] \
       && in_sandbox "$app" 'python3 -I -c "import ctypes, sys; ctypes.CDLL(sys.argv[1])" "$1"' \
            sh "$APPDIR/cac-p11-client.so" >/dev/null 2>&1; then
      BRIDGE_CLIENT="$APPDIR/cac-p11-client.so"
    else
      rm -f "$APPDIR/cac-p11-client.so"
      FP_FALLBACK=1
      warn "$name: couldn't prepare its CAC client; using the runtime's (start $name from the app menu)."
    fi
    if [[ -n $BRIDGE_CLIENT ]]; then
      BRIDGE_ENV="CAC_P11_BRIDGE_ADDRESS"
    else
      BRIDGE_ENV="P11_KIT_SERVER_ADDRESS"
    fi
    WRAPPER="$APPDIR/cac-launch.sh"
    as_user tee "$WRAPPER" >/dev/null <<EOF
#!/bin/sh
# Runs inside the Flatpak sandbox: point the CAC module at the host CAC bridge.
export $BRIDGE_ENV="unix:path=\$XDG_RUNTIME_DIR/cac-p11/opensc"
exec "$cmd" "\$@"
EOF
    chmod 755 "$WRAPPER"
    rm -f "$APPDIR/chromium-cac.sh"   # wrapper name used by earlier versions

    if [[ $kind == chromium ]]; then
      NSSDB=$(fp_nssdb "$app")
      # A per-app NSS DB lives in ~/.pki inside the sandbox; make that folder persistent.
      if [[ $NSSDB == "$APPDIR/.pki/nssdb" ]]; then as_user flatpak override --user --persist=.pki "$app"; fi
      nss_ensure_db "$NSSDB"
      nss_import_certs "$NSSDB"
      ok "$name: DoD certificates and missing site intermediates installed"
      # With the host's client it is the only CAC module; with the runtime's, the root module
      # serves the card and a separate module would be a second copy (see above).
      set_bridge_module "$NSSDB/pkcs11.txt" ${BRIDGE_CLIENT:+"$BRIDGE_CLIENT"}
      TEST_MODULE=${BRIDGE_CLIENT:-$SANDBOX_LIB/libnssckbi.so}
    else
      TEST_MODULE=${BRIDGE_CLIENT:-$SANDBOX_LIB/pkcs11/p11-kit-client.so}
      profiles=()
      while IFS= read -r db; do profiles+=("$(dirname "$db")"); done \
        < <(find "$APPDIR" -mindepth 2 -maxdepth 6 -name cert9.db -not -path '*/.pki/*' 2>/dev/null)
      if [[ ${#profiles[@]} -eq 0 ]]; then
        warn "$name has no profile yet: start it once, close it, then run this script again."
      fi
      for prof in "${profiles[@]}"; do
        nss_import_certs "$prof"
        if [[ ! -f $prof/pkcs11.txt ]]; then
          warn "$name profile $(basename "$prof") has no pkcs11.txt; add the security device by hand: $TEST_MODULE"
          continue
        fi
        set_bridge_module "$prof/pkcs11.txt" "$TEST_MODULE"
        ok "$name profile $(basename "$prof"): DoD certificates and CAC security device"
      done
    fi

    # Menu entry that starts the app through the wrapper.
    SRC_DESKTOP=""
    for d in /var/lib/flatpak/exports/share/applications "$TARGET_HOME/.local/share/flatpak/exports/share/applications"; do
      [[ -f "$d/$app.desktop" ]] && { SRC_DESKTOP="$d/$app.desktop"; break; }
    done
    if [[ -n "$SRC_DESKTOP" ]]; then
      sed -E -e "s#--command=[^ ]+#--command=$WRAPPER#" \
             -e "/^Exec=/{/--command=/!s#flatpak run#flatpak run --command=$WRAPPER#}" "$SRC_DESKTOP" \
        | as_user tee "$TARGET_HOME/.local/share/applications/$app.desktop" >/dev/null
      ok "Menu launcher starts $name with CAC support"
    else
      warn "No menu entry found for $app; start it with: flatpak run --command=$WRAPPER $app"
    fi

    # Quick self-test: the CAC must show up in the module the browser actually uses.
    if [[ -S "/run/user/$TARGET_UID/cac-p11/opensc" ]]; then
      TEST=$(in_sandbox "$app" \
        'export '"$BRIDGE_ENV"'="unix:path=$XDG_RUNTIME_DIR/cac-p11/opensc"; python3 -I -c "$1" "$2"' \
        sh "$SLOT_TEST_PY" "$TEST_MODULE" 2>/dev/null || echo err)
      self_test_result "$name" "inside the $name sandbox" "$TEST"
    fi
  done
fi

# ================================================================ 6. Army AVD
# Microsoft ships no native Linux Windows App (and it doesn't run under Wine), so Army AVD is reached
# with FreeRDP 3 (built with AAD support, checked in step 1) through the Azure Government feed.
# Sign-ins happen in a small Qt WebEngine window, which uses the CAC through NSS/p11-kit like
# Firefox does.
if [[ $WANT_AVD == 1 ]]; then
  info "Setting up the Army AVD launcher"
  # Launchers from earlier versions of this script.
  rm -f "$TARGET_HOME"/.local/bin/army-avd-{feed,freerdp} \
        "$TARGET_HOME"/.local/share/applications/army-avd{,-freerdp,-qt}.desktop
  as_user mkdir -p "$TARGET_HOME/.local/bin" "$TARGET_HOME/.local/share/applications"
  # Engine: feed, CAC sign-in window and FreeRDP.
  as_user tee "$TARGET_HOME/.local/bin/army-avd-qt" >/dev/null <<'PYEOF'
#!/usr/bin/env python3
"""Connect to Army AVD with FreeRDP 3, doing every Entra/CAC sign-in in a small Qt WebEngine
window instead of the system browser. Separate from army-avd-freerdp / army-avd-feed; its own
state lives in ~/.config/army-avd-qt and ~/.local/share/army-avd-qt. Also the engine behind
the army-avd-gui launcher window.

Usage: army-avd-qt [--login] [--choose] [--resource ID [--set-default]] [extra FreeRDP args...]
  --login        ignore the cached feed sign-in
  --choose       pick the desktop again when several are assigned
  --resource ID  connect to this feed resource (desktop or app) instead of the default
  --set-default  with --resource: also make it the default
       army-avd-qt list [--login]   print account, default and assigned resources as JSON
       army-avd-qt logout           forget the saved sign-in, account and sign-in cookies

Flow: feed sign-in (cached refresh token) -> rdweb.wvd.azure.us feed -> connection file ->
FreeRDP on a pseudo-terminal. When FreeRDP prints "Browse to:", the sign-in window opens,
captures the nativeclient?code= redirect itself, and the URL is typed into FreeRDP's prompt.
The account learned at sign-in is passed as login_hint so later sign-ins are pre-filled.
Requires: python3-pyqt6-webengine.
"""

import base64
import hashlib
import json
import os
import pty
import re
import secrets
import shutil
import signal
import subprocess
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

TENANT = os.environ.get("AVD_TENANT", "organizations")
CLIENT_ID = "a85cf173-4192-42f8-81fa-777a763e6e2c"  # Microsoft Remote Desktop (public client)
LOGIN_HOST = os.environ.get("AVD_LOGIN_HOST", "login.microsoftonline.us")
LOGIN = f"https://{LOGIN_HOST}/{TENANT}/oauth2/v2.0"
# The Remote Desktop app only accepts the commercial nativeclient redirect, even in Azure Gov.
REDIRECT = "https://login.microsoftonline.com/common/oauth2/nativeclient"
SCOPE = "https://www.wvd.azure.us/.default offline_access openid profile"
DISCOVERY = "https://rdweb.wvd.azure.us/api/arm/feeddiscovery"
MS_USER_AGENT = "com.microsoft.rdc.html/2.0.79.2 rdhtml-sdk/2.0.4"
ACCEPT_DISCOVERY = "application/x-msts-radc-discovery+xml,text/xml"
ACCEPT_FEED = "application/x-msts-radc+xml;radc_schema_version=2.0,text/xml"
TRUSTED_SUFFIXES = (".azure.us", ".microsoftonline.us", ".microsoft.com", ".microsoftonline.com")

# Debian/Ubuntu's freerdp3-x11 installs xfreerdp3; Fedora's freerdp installs xfreerdp.
FREERDP = (os.environ.get("FREERDP") or shutil.which("xfreerdp3") or shutil.which("xfreerdp")
           or "xfreerdp")
# FreeRDP settings for Azure Government. avd-access is the printf format FreeRDP fills with
# (sign-in host, tenant) for its redirect; %.0s drops the host so the .com redirect is used.
AZURE_ARG = ("/azure:ad:login.microsoftonline.us,"
             "avd-scope:https%3A%2F%2Fwww.wvd.azure.us%2F.default%20openid%20profile%20offline_access,"
             "avd-access:https%%3A%%2F%%2Flogin.microsoftonline.com%.0s%%2F%s%%2Foauth2%%2Fnativeclient")
FREERDP_OPTS = ["/smartcard", "/sound", "/microphone", "+clipboard", "/network:auto", "/gfx"]
DESKTOP_OPTS = ["/dynamic-resolution"]  # not for RemoteApps, which run as individual windows

CONF_DIR = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "army-avd-qt")
DATA_DIR = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"), "army-avd-qt")
TOKEN_FILE = os.path.join(CONF_DIR, "token.json")
ACCOUNT_FILE = os.path.join(CONF_DIR, "account.json")
CHOICE_FILE = os.path.join(CONF_DIR, "resource-id")
RESOURCES_FILE = os.path.join(CONF_DIR, "resources.json")
RDP_DIR = os.path.join(CONF_DIR, "rdp")  # one connection file per resource, so sessions can run side by side


def log(*args):
    print(*args, file=sys.stderr, flush=True)


def ask(prompt):
    sys.stderr.write(prompt)
    sys.stderr.flush()
    line = sys.stdin.readline()
    if not line:
        sys.exit("no input")
    return line.strip()


def write_private(path, text):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(text)


def read_json(path, default):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def is_redirect(url):
    p = urllib.parse.urlparse(url)
    qs = urllib.parse.parse_qs(p.query)
    return (p.scheme == "https" and (p.hostname or "").startswith("login.microsoftonline.")
            and p.path.endswith("/oauth2/nativeclient") and ("code" in qs or "error" in qs))


# ================================================================ Qt sign-in window
def qt_login(start_url):
    """Show the sign-in window; print the captured redirect URL on stdout. Exit 1 if closed."""
    import ctypes
    from PyQt6.QtCore import QObject, Qt, QTimer, QUrl, pyqtSignal
    from PyQt6.QtWidgets import QApplication, QInputDialog, QLineEdit, QMessageBox
    from PyQt6.QtWebEngineCore import (QWebEnginePage, QWebEngineProfile,
                                       QWebEngineUrlRequestInterceptor)
    from PyQt6.QtWebEngineWidgets import QWebEngineView

    app = QApplication([sys.argv[0], "--disable-gpu"])
    app.setApplicationName("Army AVD sign-in")
    result = {"url": None}

    class Bridge(QObject):
        found = pyqtSignal(str)
        pin_needed = pyqtSignal(str, bool, object)

    bridge = Bridge()

    def finish(url):
        # Runs from the event loop (queued), never inside a WebEngine navigation callback:
        # tearing the page down from there crashes Chromium. Hand the URL over and exit
        # without Qt/Chromium teardown.
        if result["url"] is None:
            result["url"] = url
            sys.stdout.write(url + "\n")
            sys.stdout.flush()
            os._exit(0)

    bridge.found.connect(finish, Qt.ConnectionType.QueuedConnection)

    # ---- capture the redirect before it is loaded (covers server redirects too)
    class Interceptor(QWebEngineUrlRequestInterceptor):
        def interceptRequest(self, info):
            url = info.requestUrl().toString()
            if is_redirect(url):
                info.block(True)
                bridge.found.emit(url)

    class Page(QWebEnginePage):
        def acceptNavigationRequest(self, url, nav_type, is_main_frame):
            if is_redirect(url.toString()):
                bridge.found.emit(url.toString())
                return False
            return super().acceptNavigationRequest(url, nav_type, is_main_frame)

    # Persistent cookies so the second sign-in (FreeRDP's) can reuse the session.
    profile = QWebEngineProfile("army-avd", app)
    profile.setPersistentStoragePath(os.path.join(DATA_DIR, "web"))
    profile.setCachePath(os.path.join(DATA_DIR, "cache"))
    profile.setPersistentCookiesPolicy(QWebEngineProfile.PersistentCookiesPolicy.ForcePersistentCookies)
    interceptor = Interceptor()
    profile.setUrlRequestInterceptor(interceptor)
    page = Page(profile)

    # ---- client certificate: prefer the CAC authentication certificate
    def cert_label(cert):
        cn = ", ".join(cert.subjectInfo(cert.SubjectInfo.CommonName)) or "?"
        issuer = ", ".join(cert.issuerInfo(cert.SubjectInfo.CommonName)) or "?"
        return f"{cn}  (issued by {issuer})"

    def eku(cert):
        for ext in cert.extensions():
            if ext.oid() == "2.5.29.37":
                val = ext.value()
                return [str(v) for v in val] if isinstance(val, (list, tuple)) else [str(val)]
        return []

    def select_cert(selection):
        certs = list(selection.certificates())
        log(f"[army-avd-qt] site requests a client certificate; {len(certs)} offered")
        for c in certs:
            log("   ", cert_label(c), "EKU:", eku(c))
        auth = [c for c in certs if any("Client Auth" in u or "Smartcard" in u for u in eku(c))
                and not any("Mail" in u for u in eku(c))]
        if len(auth) == 1:
            selection.select(auth[0])
            return
        if not certs:
            QMessageBox.warning(view, "Army AVD sign-in",
                                "No certificates found. Is your CAC inserted?")
            selection.selectNone()
            return
        labels = [cert_label(c) + "  " + ", ".join(eku(c)) for c in certs]
        choice, ok = QInputDialog.getItem(view, "Army AVD sign-in",
                                          "Choose your CAC authentication certificate:",
                                          labels, 0, False)
        if ok:
            selection.select(certs[labels.index(choice)])
        else:
            selection.selectNone()

    page.selectClientCertificate.connect(select_cert)

    # ---- CAC PIN: Qt WebEngine has no smart card PIN UI, so supply NSS's password callback.
    nss = ctypes.CDLL("libnss3.so")
    nss.NSS_IsInitialized.restype = ctypes.c_int
    nss.PK11_GetTokenName.restype = ctypes.c_char_p
    nss.PK11_GetTokenName.argtypes = [ctypes.c_void_p]
    nss.PORT_Strdup.restype = ctypes.c_void_p  # NSS frees the PIN buffer with PORT_Free
    nss.PORT_Strdup.argtypes = [ctypes.c_char_p]
    PWFUNC = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p)
    nss.PK11_SetPasswordFunc.argtypes = [PWFUNC]
    failures = {"n": 0}

    def ask_pin(token, retry, box):
        if retry:
            failures["n"] += 1
        if failures["n"] >= 2:
            QMessageBox.critical(view, "Army AVD sign-in",
                                 "The CAC rejected the PIN twice. Stopping so the card doesn't lock.")
            box["pin"] = None
        else:
            msg = ("Incorrect PIN - try again carefully.\n\n" if retry else "") + \
                  f"Enter the PIN for {token}:"
            pin, ok = QInputDialog.getText(view, "CAC PIN", msg, QLineEdit.EchoMode.Password)
            box["pin"] = pin if ok and pin else None
        box["done"].set()

    bridge.pin_needed.connect(ask_pin)

    def password_cb(slot, retry, _arg):
        token = (nss.PK11_GetTokenName(slot) or b"CAC").decode(errors="replace").strip()
        box = {"done": threading.Event(), "pin": None}
        if threading.current_thread() is threading.main_thread():
            ask_pin(token, bool(retry), box)
        else:
            bridge.pin_needed.emit(token, bool(retry), box)
            box["done"].wait()
        return nss.PORT_Strdup(box["pin"].encode()) if box["pin"] else None

    callback = PWFUNC(password_cb)  # keep a reference for the process lifetime

    def install_pin_callback():
        # Chromium sets its own callback right after initializing NSS; keep ours in place.
        if nss.NSS_IsInitialized():
            nss.PK11_SetPasswordFunc(callback)

    pin_timer = QTimer()
    pin_timer.timeout.connect(install_pin_callback)
    pin_timer.start(200)

    view = QWebEngineView()
    view.setPage(page)
    view.setWindowTitle("Army AVD sign-in")
    view.resize(520, 720)
    page.titleChanged.connect(lambda t: view.setWindowTitle(f"Army AVD sign-in - {t}"))
    view.load(QUrl(start_url))
    view.show()
    app.exec()
    # Only reached when the window was closed without a redirect; skip the teardown here too.
    os._exit(1)


def login_via_window(url):
    """Run the sign-in window in a child process and return the redirect URL."""
    proc = subprocess.run([sys.executable, "-I", os.path.abspath(__file__), "_login", url],
                          stdout=subprocess.PIPE, text=True)
    redirect = proc.stdout.strip()
    if proc.returncode != 0 or not is_redirect(redirect):
        return None
    return redirect



# ================================================================ account
def saved_upn():
    return read_json(ACCOUNT_FILE, {}).get("upn", "")


def remember_upn(tok):
    """Learn the signed-in account from the id_token so later sign-ins can be pre-filled."""
    idt = tok.get("id_token", "")
    if idt.count(".") < 2:
        return
    try:
        payload = idt.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    except ValueError:
        return
    upn = claims.get("preferred_username") or claims.get("upn") or claims.get("email") or ""
    if upn:
        write_private(ACCOUNT_FILE, json.dumps({"upn": upn, "name": claims.get("name", "")}))


def with_login_hint(url):
    """Add the remembered account as login_hint to an Entra authorize URL (unless present)."""
    upn = saved_upn()
    if not upn or "login_hint=" in url:
        return url
    return url + ("&" if "?" in url else "?") + "login_hint=" + urllib.parse.quote(upn)


def close_login_windows():
    """End any open sign-in windows; one still running would write its cookies back on exit."""
    me = os.path.abspath(__file__)
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as fh:
                argv = fh.read().split(b"\0")
            if me.encode() in argv and b"_login" in argv:
                os.kill(int(pid), signal.SIGTERM)
        except (OSError, ValueError):
            pass


def logout():
    """Forget the saved sign-in and everything the sign-in window remembers (cookies, cache and
    the sign-in method Microsoft's page last used), so the next sign-in starts from scratch."""
    close_login_windows()
    for path in (TOKEN_FILE, ACCOUNT_FILE):
        if os.path.exists(path):
            os.remove(path)
    for sub in ("web", "cache"):
        shutil.rmtree(os.path.join(DATA_DIR, sub), ignore_errors=True)
    log("Signed out: saved sign-in, account, and the sign-in window's cookies and cache removed.")


# ================================================================ feed
def is_trusted(url):
    p = urllib.parse.urlparse(url)
    host = (p.hostname or "").lower()
    return p.scheme == "https" and any(host.endswith(s) for s in TRUSTED_SUFFIXES)


def post(url, data):
    req = urllib.request.Request(url, data=urllib.parse.urlencode(data).encode(), method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode())
        except ValueError:
            return e.code, {"error": f"HTTP {e.code}"}


def get(url, token, accept="*/*"):
    if not is_trusted(url):
        sys.exit(f"Refusing to send the sign-in token to untrusted URL: {url}")
    req = urllib.request.Request(url)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Accept", accept)
    req.add_header("User-Agent", MS_USER_AGENT)
    req.add_header("X-MS-User-Agent", MS_USER_AGENT)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")


def b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def interactive_login(hint):
    verifier = b64url(secrets.token_bytes(64))
    challenge = b64url(hashlib.sha256(verifier.encode()).digest())
    state = secrets.token_urlsafe(16)
    params = {"client_id": CLIENT_ID, "response_type": "code", "redirect_uri": REDIRECT,
              "scope": SCOPE, "code_challenge": challenge, "code_challenge_method": "S256",
              "state": state}
    if hint:
        params["login_hint"] = hint
    else:
        params["prompt"] = "select_account"
    log("Signing in to the AVD feed (sign-in window)...")
    redirect = login_via_window(LOGIN + "/authorize?" + urllib.parse.urlencode(params))
    if not redirect:
        sys.exit("Sign-in window closed without completing.")
    qs = urllib.parse.parse_qs(urllib.parse.urlparse(redirect).query)
    if "error" in qs:
        sys.exit("Sign-in error: " + (qs.get("error_description") or qs["error"])[0])
    if qs.get("state", [""])[0] != state:
        sys.exit("State mismatch - aborting for safety; try again.")
    st, tok = post(LOGIN + "/token", {
        "grant_type": "authorization_code", "client_id": CLIENT_ID, "code": qs["code"][0],
        "redirect_uri": REDIRECT, "scope": SCOPE, "code_verifier": verifier})
    if st != 200:
        sys.exit(f"Token exchange failed ({st}): {tok.get('error', '')}: "
                 f"{tok.get('error_description', '')[:400]}")
    return tok


def access_token(force_login):
    cached = read_json(TOKEN_FILE, {})
    tok = None
    if cached.get("refresh_token") and not force_login:
        st, tok = post(LOGIN + "/token", {
            "grant_type": "refresh_token", "client_id": CLIENT_ID, "scope": SCOPE,
            "refresh_token": cached["refresh_token"]})
        if st != 200:
            log(f"Cached sign-in expired ({tok.get('error', st)}); signing in again.")
            tok = None
    if tok is None:
        tok = interactive_login("" if force_login else saved_upn())
    remember_upn(tok)
    write_private(TOKEN_FILE, json.dumps(
        {"refresh_token": tok.get("refresh_token") or cached.get("refresh_token", "")}))
    return tok["access_token"]


def local(tag):
    return tag.split("}")[-1]


def list_resources(token):
    st, body = get(DISCOVERY, token, ACCEPT_DISCOVERY)
    if st != 200:
        sys.exit(f"Feed discovery failed ({st}): {body[:400]}")
    feeds = [el.attrib for el in ET.fromstring(body).iter() if local(el.tag) == "TenantFeedURL"]
    resources = []
    for feed in feeds:
        url = feed.get("FeedURL")
        if not url:
            continue
        st, body = get(url, token, ACCEPT_FEED)
        if st != 200:
            log(f"  ! workspace feed {feed.get('TenantDisplayName', '?')} failed ({st})")
            continue
        for res in ET.fromstring(body).iter():
            if local(res.tag) != "Resource":
                continue
            rf = next((c for c in res.iter() if local(c.tag) == "ResourceFile"), None)
            if rf is None or not rf.attrib.get("URL"):
                continue
            resources.append({"id": res.attrib.get("ID", ""), "title": res.attrib.get("Title", "?"),
                              "type": res.attrib.get("Type", "?"),
                              "workspace": feed.get("TenantDisplayName", ""),
                              "url": rf.attrib["URL"]})
    if not resources:
        sys.exit("No desktops or apps are assigned to this account in the AVD feed.")
    write_private(RESOURCES_FILE, json.dumps(resources, indent=1))
    return resources


def saved_choice():
    try:
        with open(CHOICE_FILE) as fh:
            return fh.read().strip()
    except OSError:
        return ""


def choose(resources, rechoose):
    saved = "" if rechoose else saved_choice()
    for r in resources:
        if r["id"] and r["id"] == saved:
            return r
    if len(resources) == 1:
        pick = resources[0]
    else:
        log("\nAssigned resources:")
        for i, r in enumerate(resources, 1):
            log(f"  [{i}] {r['title']}  ({r['type']}, {r['workspace']})")
        while True:
            ans = ask(f"Choose 1-{len(resources)}: ")
            if ans.isdigit() and 1 <= int(ans) <= len(resources):
                pick = resources[int(ans) - 1]
                break
    write_private(CHOICE_FILE, pick["id"])
    return pick


def rdp_path(resource_id, suffix=".rdp"):
    return os.path.join(RDP_DIR, hashlib.sha256(resource_id.encode()).hexdigest()[:16] + suffix)


def fetch_connection(force_login, rechoose, resource_id, set_default):
    """Return (rdp_path, access_token) from the feed, or the saved file with no token."""
    wanted = resource_id or ("" if rechoose else saved_choice())
    try:
        token = access_token(force_login)
        log("Querying " + DISCOVERY)
        resources = list_resources(token)
        if resource_id:
            res = next((r for r in resources if r["id"] == resource_id), None)
            if res is None:
                sys.exit("That desktop/app is no longer in your AVD feed; refresh the list.")
            if set_default:
                write_private(CHOICE_FILE, res["id"])
        else:
            res = choose(resources, rechoose)
        st, rdp = get(res["url"], token)
        if st != 200:
            sys.exit(f"Downloading the connection file failed ({st}): {rdp[:300]}")
        path = rdp_path(res["id"])
        write_private(path, rdp)
        log(f"Got connection file for '{res['title']}' ({res['workspace']})")
        return path, token
    except (SystemExit, OSError, urllib.error.URLError) as e:
        if wanted and os.path.exists(rdp_path(wanted)):
            log(f"Feed lookup failed ({e}); reusing the last connection file.")
            return rdp_path(wanted), None
        raise


# ================================================================ FreeRDP
def connect_copy(path):
    """Return (connect_path, is_remoteapp). AVD files ship 'smart sizing:i:1', which FreeRDP
    rejects with /dynamic-resolution; desktops also open windowed."""
    with open(path, "rb") as fh:
        raw = fh.read()
    text = raw.decode("utf-16") if raw[:2] == b"\xff\xfe" else raw.decode("utf-8", "replace")
    lines = [ln for ln in text.replace("\r", "").split("\n") if ln]
    remoteapp = any(ln.lower().replace(" ", "") == "remoteapplicationmode:i:1" for ln in lines)
    drop = ("smart sizing",) if remoteapp else ("smart sizing", "screen mode id")
    lines = [ln for ln in lines if ln.split(":", 1)[0].strip().lower() not in drop]
    lines += ["smart sizing:i:0"] + ([] if remoteapp else ["screen mode id:i:1"])
    out = path[:-len(".rdp")] + ".connect.rdp"
    write_private(out, "\n".join(lines) + "\n")
    return out, remoteapp


BROWSE_RE = re.compile(rb"Browse to: (https://\S+)")


def run_freerdp(argv):
    """Run FreeRDP on a pseudo-terminal; answer each 'Browse to:' prompt via the sign-in window."""
    handled = set()
    buf = b""

    def answer(fd, url):
        redirect = login_via_window(with_login_hint(url))
        if redirect:
            os.write(sys.stdout.fileno(), b"\r\n[army-avd-qt] Sign-in captured.\r\n")
            os.write(fd, redirect.encode() + b"\n")
        else:
            os.write(sys.stdout.fileno(), b"\r\n[army-avd-qt] Sign-in window closed; paste the "
                     b"redirect URL manually or press Ctrl+C.\r\n")

    def master_read(fd):
        nonlocal buf
        data = os.read(fd, 4096)
        buf = (buf + data)[-8192:]
        for m in BROWSE_RE.finditer(buf):
            url = m.group(1).decode(errors="replace")
            if url in handled or not url.startswith("https://login.microsoftonline."):
                continue
            handled.add(url)
            threading.Thread(target=answer, args=(fd, url), daemon=True).start()
        return data

    return os.waitstatus_to_exitcode(pty.spawn(argv, master_read))


def take_option(args, name):
    """Remove '--name VALUE' from args and return VALUE (or None)."""
    if name in args:
        i = args.index(name)
        if i + 1 >= len(args):
            sys.exit(f"{name} needs a value")
        value = args[i + 1]
        del args[i:i + 2]
        return value
    return None


def main():
    if sys.argv[1:2] == ["_login"]:
        qt_login(sys.argv[2])
        return
    try:
        import PyQt6.QtWebEngineWidgets  # noqa: F401
    except ImportError:
        sys.exit("PyQt6 WebEngine is not installed. Run:  sudo dnf install python3-pyqt6-webengine"
                 "  (Fedora)  or  sudo apt install python3-pyqt6.qtwebengine  (Ubuntu/Debian)")
    args = sys.argv[1:]
    if args[:1] == ["logout"]:
        logout()
        return
    if args[:1] == ["list"]:
        resources = list_resources(access_token("--login" in args))
        print(json.dumps({"account": read_json(ACCOUNT_FILE, {}), "default": saved_choice(),
                          "resources": resources}))
        return

    resource_id = take_option(args, "--resource")
    flags = {"--login", "--choose", "--set-default"}
    extra = [a for a in args if a not in flags]
    if any(a in ("-h", "--help") for a in extra):
        sys.exit(__doc__)

    rdp, token = fetch_connection("--login" in args, "--choose" in args, resource_id,
                                  "--set-default" in args)
    connect_file, remoteapp = connect_copy(rdp)
    gateway = "/gateway:type:arm" + (f",bearer:{token}" if token else "")
    freerdp_args = ([connect_file, gateway, AZURE_ARG] + FREERDP_OPTS
                    + ([] if remoteapp else DESKTOP_OPTS) + extra)
    # Arguments go through the environment so the bearer token doesn't show up in 'ps'.
    os.environ["FREERDP_ARGS"] = "\n".join(freerdp_args)
    log("Starting FreeRDP" + (" (RemoteApp)" if remoteapp else "") + "...")
    sys.exit(run_freerdp([FREERDP, "/args-from:env:FREERDP_ARGS"]))


if __name__ == "__main__":
    try:
        main()
    except SystemExit as e:
        # Keep the launcher's terminal open on failure so the message can be read.
        if e.code not in (0, None) and sys.argv[1:2] != ["_login"] and sys.stdin.isatty():
            if isinstance(e.code, str):
                log(e.code)
            input("Exited with an error. Press Enter to close...")
            sys.exit(1)
        raise
PYEOF
  # Launcher window: pick a desktop/app and connect.
  as_user tee "$TARGET_HOME/.local/bin/army-avd-gui" >/dev/null <<'GUIEOF'
#!/usr/bin/env python3
"""Army AVD launcher window: pick a desktop or app from your AVD feed and connect with FreeRDP.

A front end for army-avd-qt (the engine, which does the feed, the CAC sign-in windows and
FreeRDP). Reads the engine's saved state in ~/.config/army-avd-qt: the account, the default
resource and the last resource list, then refreshes the list from the feed in the background.
"""

import json
import os
import re
import sys

from PyQt6.QtCore import QProcess, QProcessEnvironment, Qt
from PyQt6.QtGui import QFont, QIcon
from PyQt6.QtWidgets import (QApplication, QCheckBox, QComboBox, QHBoxLayout, QLabel,
                             QMessageBox, QPlainTextEdit, QPushButton, QVBoxLayout, QWidget)

ENGINE = os.environ.get("ARMY_AVD_ENGINE") or os.path.join(
    os.path.dirname(os.path.realpath(__file__)), "army-avd-qt")
CONF_DIR = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "army-avd-qt")
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
# The sign-in code FreeRDP echoes back is single-use, but keep it out of the log anyway.
CODE_RE = re.compile(r"(code=)[^&\s]+")


def read_json(name, default):
    try:
        with open(os.path.join(CONF_DIR, name)) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def read_default():
    try:
        with open(os.path.join(CONF_DIR, "resource-id")) as fh:
            return fh.read().strip()
    except OSError:
        return ""


def region(res):
    ws = res.get("workspace", "")
    return ws.rsplit(" - ", 1)[-1] if " - " in ws else ws


def is_logoff(res):
    return res.get("title", "").strip().lower() in ("logoff", "log off", "sign out")


class Launcher(QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Army AVD")
        icon_file = os.path.expanduser("~/.local/share/icons/hicolor/scalable/apps/army-avd.svg")
        self.setWindowIcon(QIcon.fromTheme("army-avd", QIcon(icon_file) if os.path.exists(icon_file)
                                           else QIcon.fromTheme("preferences-desktop-remote-desktop")))
        self.resize(520, 420)
        self.resources = []
        self.default_id = ""
        self.sessions = []      # running connect QProcesses
        self.refresher = None   # running 'list' QProcess

        self.account = QLabel()
        self.switch_btn = QPushButton("Clear sign-in…")
        self.switch_btn.setToolTip("Forget the saved sign-in and what the sign-in window remembers, "
                                   "then sign in again (also for switching accounts)")
        self.switch_btn.clicked.connect(self.clear_sign_in)
        top = QHBoxLayout()
        top.addWidget(self.account, 1)
        top.addWidget(self.switch_btn)

        self.combo = QComboBox()
        self.combo.currentIndexChanged.connect(self.selection_changed)
        self.make_default = QCheckBox("Make this my default")

        self.refresh_btn = QPushButton("Refresh list")
        self.refresh_btn.clicked.connect(lambda: self.refresh(False))
        self.stop_btn = QPushButton("Disconnect all")
        self.stop_btn.clicked.connect(self.stop_all)
        self.connect_btn = QPushButton("Connect")
        self.connect_btn.setDefault(True)
        self.connect_btn.clicked.connect(self.connect_selected)
        buttons = QHBoxLayout()
        buttons.addWidget(self.refresh_btn)
        buttons.addWidget(self.stop_btn)
        buttons.addStretch(1)
        buttons.addWidget(self.connect_btn)

        self.status = QLabel()
        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setMaximumBlockCount(2000)
        self.log.setFont(QFont("monospace", 8))
        self.log.setPlaceholderText("Details appear here.")

        layout = QVBoxLayout(self)
        layout.addLayout(top)
        layout.addSpacing(6)
        layout.addWidget(QLabel("Connect to:"))
        layout.addWidget(self.combo)
        layout.addWidget(self.make_default)
        layout.addLayout(buttons)
        layout.addWidget(self.status)
        layout.addWidget(self.log, 1)

        self.load_cached()
        self.update_buttons()
        self.refresh(False)

    # ------------------------------------------------------------ state
    def load_cached(self):
        acct = read_json("account.json", {})
        self.show_account(acct)
        self.populate(read_json("resources.json", []), read_default())

    def show_account(self, acct):
        upn = acct.get("upn", "")
        self.account.setText(f"Signed in as: <b>{upn}</b>" if upn else "Not signed in yet")

    def populate(self, resources, default_id):
        current = self.combo.currentData()
        self.resources, self.default_id = resources, default_id
        self.combo.blockSignals(True)
        self.combo.clear()
        groups = [("Desktops", [r for r in resources if r.get("type") == "Desktop"]),
                  ("Apps", [r for r in resources if r.get("type") != "Desktop" and not is_logoff(r)]),
                  ("Sign out of a session", [r for r in resources if is_logoff(r)])]
        for header, items in groups:
            if not items:
                continue
            if self.combo.count():
                self.combo.insertSeparator(self.combo.count())
            self.combo.addItem(header)
            item = self.combo.model().item(self.combo.count() - 1)
            item.setEnabled(False)
            item.setData(QFont("", -1, QFont.Weight.Bold), Qt.ItemDataRole.FontRole)
            for r in sorted(items, key=lambda r: (r["title"], region(r))):
                star = "★ " if r["id"] == default_id else "    "
                self.combo.addItem(f"{star}{r['title']} — {region(r)}", r["id"])
        wanted = current or default_id
        idx = self.combo.findData(wanted) if wanted else -1
        if idx < 0:
            idx = next((i for i in range(self.combo.count()) if self.combo.itemData(i)), -1)
        self.combo.setCurrentIndex(idx)
        self.combo.blockSignals(False)
        self.selection_changed()

    def selected(self):
        rid = self.combo.currentData()
        return next((r for r in self.resources if r["id"] == rid), None)

    def selection_changed(self):
        res = self.selected()
        is_default = bool(res) and res["id"] == self.default_id
        self.make_default.setChecked(is_default)
        self.make_default.setEnabled(bool(res) and not is_default and not is_logoff(res))
        self.update_buttons()

    def update_buttons(self):
        busy = self.refresher is not None
        self.connect_btn.setEnabled(self.selected() is not None)
        self.refresh_btn.setEnabled(not busy)
        self.switch_btn.setEnabled(not busy)
        self.stop_btn.setEnabled(bool(self.sessions))
        if busy:
            self.status.setText("Refreshing the list from the AVD feed…")
        elif self.sessions:
            self.status.setText(f"{len(self.sessions)} session(s) running.")
        elif not self.resources:
            self.status.setText("No desktops listed yet.")

    # ------------------------------------------------------------ helpers
    def append_log(self, text):
        text = CODE_RE.sub(r"\1…", ANSI_RE.sub("", text.replace("\r", "")))
        for line in text.splitlines():
            if line.strip():
                self.log.appendPlainText(line)

    def engine(self, args):
        proc = QProcess(self)
        env = QProcessEnvironment.systemEnvironment()
        env.insert("PYTHONUNBUFFERED", "1")
        proc.setProcessEnvironment(env)
        proc.setProgram(sys.executable)
        proc.setArguments(["-I", ENGINE] + args)
        return proc

    # ------------------------------------------------------------ actions
    def refresh(self, fresh_login):
        if self.refresher is not None:
            return
        proc = self.engine(["list"] + (["--login"] if fresh_login else []))
        out = []
        proc.readyReadStandardOutput.connect(
            lambda: out.append(bytes(proc.readAllStandardOutput()).decode(errors="replace")))
        proc.readyReadStandardError.connect(
            lambda: self.append_log(bytes(proc.readAllStandardError()).decode(errors="replace")))

        def done(code, _status):
            self.refresher = None
            if code == 0:
                try:
                    data = json.loads("".join(out))
                except ValueError:
                    data = None
                if data:
                    self.show_account(data.get("account", {}))
                    self.populate(data.get("resources", []), data.get("default", ""))
                    self.status.setText(f"{len(self.resources)} item(s) in your AVD feed.")
            else:
                self.status.setText("Couldn't refresh the list - see details below.")
            self.update_buttons()

        proc.finished.connect(done)
        self.refresher = proc
        proc.start()
        self.update_buttons()

    def connect_selected(self):
        res = self.selected()
        if not res:
            return
        if is_logoff(res) and QMessageBox.question(
                self, "Army AVD", f"This signs you out of your AVD session in {region(res)}.\n"
                "Unsaved work in that session may be lost. Continue?") \
                != QMessageBox.StandardButton.Yes:
            return
        args = ["--resource", res["id"]]
        if self.make_default.isChecked() and res["id"] != self.default_id:
            args.append("--set-default")
            self.populate(self.resources, res["id"])
        proc = self.engine(args)
        proc.setProcessChannelMode(QProcess.ProcessChannelMode.MergedChannels)
        name = f"{res['title']} — {region(res)}"
        proc.readyReadStandardOutput.connect(
            lambda: self.append_log(bytes(proc.readAllStandardOutput()).decode(errors="replace")))

        def done(code, _status):
            if proc in self.sessions:
                self.sessions.remove(proc)
            self.append_log(f"── {name}: ended (exit code {code})")
            self.update_buttons()
            if code not in (0, 12):  # FreeRDP 12 = user/remote logoff
                self.status.setText(f"{name} ended with an error - see details below.")

        proc.finished.connect(done)
        self.sessions.append(proc)
        self.append_log(f"── Connecting to {name}")
        proc.start()
        self.update_buttons()

    def clear_sign_in(self):
        text = ("Forget the saved sign-in and everything the sign-in window remembers (cookies, "
                "cache and the sign-in method you picked last time), then sign in again?\n\n"
                "Use this when a sign-in is stuck on the wrong method or account.")
        if self.sessions:
            text += f"\n\nYour {len(self.sessions)} running session(s) will be disconnected."
        if QMessageBox.question(self, "Army AVD", text) != QMessageBox.StandardButton.Yes:
            return
        self.stop_all()
        proc = self.engine(["logout"])
        proc.start()
        proc.waitForFinished(10000)
        self.append_log(bytes(proc.readAllStandardError()).decode(errors="replace"))
        self.show_account({})
        self.populate([], "")
        self.refresh(True)

    def stop_all(self):
        for proc in list(self.sessions):
            proc.terminate()
            if not proc.waitForFinished(3000):
                proc.kill()

    def closeEvent(self, event):
        if self.sessions and QMessageBox.question(
                self, "Army AVD", "Closing this window disconnects your running session(s). Close?") \
                != QMessageBox.StandardButton.Yes:
            event.ignore()
            return
        # The widgets are going away; don't let finished-handlers touch them afterwards.
        for proc in self.sessions + ([self.refresher] if self.refresher else []):
            proc.finished.disconnect()
        self.stop_all()
        if self.refresher is not None:
            self.refresher.kill()
            self.refresher.waitForFinished(2000)
        event.accept()


def main():
    app = QApplication(sys.argv)
    app.setApplicationName("Army AVD")
    app.setDesktopFileName("army-avd-gui")
    win = Launcher()
    win.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
GUIEOF
  chmod 755 "$TARGET_HOME/.local/bin/army-avd-qt" "$TARGET_HOME/.local/bin/army-avd-gui"
  # Launcher icon (monitor + cloud + CAC card), shipped next to this script in assets/.
  AVD_ICON=preferences-desktop-remote-desktop
  if [[ -f "$SCRIPT_DIR/assets/army-avd.svg" ]]; then
    as_user install -Dm644 "$SCRIPT_DIR/assets/army-avd.svg" \
      "$TARGET_HOME/.local/share/icons/hicolor/scalable/apps/army-avd.svg"
    AVD_ICON=army-avd
  else
    warn "assets/army-avd.svg not found next to the script; using a stock icon."
  fi
  as_user gtk-update-icon-cache -f -t "$TARGET_HOME/.local/share/icons/hicolor" &>/dev/null || true
  as_user tee "$TARGET_HOME/.local/share/applications/army-avd-gui.desktop" >/dev/null <<EOF
[Desktop Entry]
Type=Application
Name=Army AVD
Comment=Choose an Army AVD desktop or app and connect with your CAC
Exec=$TARGET_HOME/.local/bin/army-avd-gui
Icon=$AVD_ICON
Categories=Network;RemoteAccess;
Terminal=false
StartupWMClass=army-avd-gui
EOF
  # Desktop icon (Plasma/GNOME require the executable bit to launch .desktop files from the desktop).
  DESKTOP_DIR=$(as_user xdg-user-dir DESKTOP 2>/dev/null || echo "$TARGET_HOME/Desktop")
  if [[ -d "$DESKTOP_DIR" && "$DESKTOP_DIR" != "$TARGET_HOME" ]]; then
    rm -f "$DESKTOP_DIR"/army-avd-{freerdp,qt}.desktop
    as_user install -m 755 "$TARGET_HOME/.local/share/applications/army-avd-gui.desktop" \
      "$DESKTOP_DIR/army-avd-gui.desktop"
    as_user gio set "$DESKTOP_DIR/army-avd-gui.desktop" metadata::trusted true 2>/dev/null || true
  fi
  as_user update-desktop-database "$TARGET_HOME/.local/share/applications" 2>/dev/null || true
  command -v kbuildsycoca6 &>/dev/null && as_user env XDG_RUNTIME_DIR="/run/user/$TARGET_UID" kbuildsycoca6 &>/dev/null || true
  ok "Army AVD launcher installed (menu + desktop icon: 'Army AVD')"
fi

# ================================================================ summary
echo
info "Done. Next steps:"
step=1
if [[ $HAVE_READER == 0 ]]; then
  echo "  $step. Plug in your card reader and insert your CAC (no reader was found during setup)."
  step=$((step + 1))
elif [[ $HAVE_CARD == 0 ]]; then
  echo "  $step. Insert your CAC (chip first) before you sign in anywhere."
  step=$((step + 1))
fi
if [[ ${#CHOSEN[@]} -gt 0 ]]; then
  echo "  $step. Open $(join ", " "${CHOSEN[@]}") and sign in to a CAC site, e.g."
  echo "     https://www.militarycac.com/testcac.htm (choose your authentication certificate, enter your PIN)."
  step=$((step + 1))
fi
if sel firefox || sel firefox-snap; then
  echo "  $step. Firefox: Settings > Privacy & Security > Security Devices should list your CAC under"
  echo "     \"p11-kit-proxy\" (Fedora) or \"$MODULE_NAME\"."
  step=$((step + 1))
fi
if sel chromium-snap; then
  echo "  $step. Chromium (Snap): start it from the app menu. Other ways of starting it (a terminal, links"
  echo "     from other apps) get the CAC after you log out and back in."
  step=$((step + 1))
fi
if [[ ${#SEL_FLATPAKS[@]} -gt 0 ]]; then
  if [[ $FP_FALLBACK == 0 ]]; then
    echo "  $step. Flatpak browsers reach the CAC however they're started. If one was open during setup,"
    echo "     restart it. Bridge logs: journalctl --user -u 'cac-p11-bridge@*'"
  else
    echo "  $step. Start Flatpak browsers from the app menu: those entries launch them with the CAC bridge"
    echo "     ('flatpak run <app>' from a terminal does not). Bridge logs: journalctl --user -u 'cac-p11-bridge@*'"
  fi
  step=$((step + 1))
fi
if [[ $WANT_AVD == 1 ]]; then
  echo "  $step. Army AVD: open \"Army AVD\", pick your desktop and click Connect. Sign in with your CAC"
  echo "     in the sign-in window; later sign-ins are cached and pre-filled."
fi
echo "  Certificates: $CERT_DIR"
