#!/bin/sh
# atpage desktop installer for macOS and Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/danloh/atpage-release/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/danloh/atpage-release/main/install.sh | sh -s -- --update
#
# Run with --help for every option. Windows: use install.ps1.
#
# Installs the release assets published at https://github.com/danloh/atpage-release:
#   Linux  deb (Debian/Ubuntu), rpm (Fedora/openSUSE/RHEL) or AppImage (any distro, per user)
#   macOS  atpage.app from the per-architecture .app.tar.gz (or the .dmg)
# Downloads are verified against the SHA-256 digests GitHub records for release assets.
#
# The whole script is wrapped in functions and `main` runs on the last line, so a
# truncated download never executes half a script.

set -eu

SCRIPT_VERSION="1.0.0"
REPO="${ATPAGE_REPO:-danloh/atpage-release}"
GH_URL="https://github.com/$REPO"
API_URL="https://api.github.com/repos/$REPO"

APP_NAME="atpage"             # productName: atpage.app, desktop entry name
PKG_NAME="atpage"             # deb/rpm package name
BIN_NAME="atpage-client"      # main binary / process name
SCHEME="app.atpage"           # deep-link URL scheme (OAuth sign-in callback)
IDENTIFIER="app.atpage.client" # bundle identifier, names the app data directories

ACTION="install"
VERSION_REQ="latest"
FORMAT=""
INSTALL_DIR=""
PURGE=0
YES=0
FORCE=0
DRY_RUN=0

TMP_DIR=""
REL_JSON=""

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

setup_colors() {
  if [ -t 2 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    C_B=$(printf '\033[1m'); C_D=$(printf '\033[2m'); C_R=$(printf '\033[31m')
    C_G=$(printf '\033[32m'); C_Y=$(printf '\033[33m'); C_0=$(printf '\033[0m')
  else
    C_B=""; C_D=""; C_R=""; C_G=""; C_Y=""; C_0=""
  fi
}

say()  { printf '%s\n' "$*" >&2; }
info() { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*" >&2; }
ok()   { printf '%s✓%s %s\n' "$C_G" "$C_0" "$*" >&2; }
warn() { printf '%swarning:%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

# Troubleshooting check lines.
chk_ok()   { printf '  %s[ ok ]%s %s\n' "$C_G" "$C_0" "$*"; }
chk_warn() { printf '  %s[warn]%s %s\n' "$C_Y" "$C_0" "$*"; }
chk_fail() { printf '  %s[fail]%s %s\n' "$C_R" "$C_0" "$*"; }
chk_info() { printf '  %s[info]%s %s\n' "$C_D" "$C_0" "$*"; }
section()  { printf '\n%s%s%s\n' "$C_B" "$*" "$C_0"; }

usage() {
  cat <<EOF
atpage installer for macOS and Linux (script $SCRIPT_VERSION)

Usage:
  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sh -s -- [options]
  sh install.sh [options]

Actions (default: --install):
  -i, --install             Install atpage (updates it if another version is installed)
  -u, --update              Update an existing installation to the target version
      --uninstall           Remove atpage (add --purge to also delete local app data)
  -r, --repair              Reinstall the installed version and re-register the
                            app.atpage:// sign-in handler, desktop entry and icon
  -t, --troubleshoot        Diagnose the installation and system (no changes made)
  -c, --check               Show the installed and the latest version
  -l, --list                List published versions

Options:
  -v, --version <X.Y.Z>     Target version (alias --target-version; default: latest)
  -f, --format <format>     Linux: deb | rpm | appimage   macOS: app | dmg
                            (default: the installed format, else deb/rpm when the
                            system package manager supports it, else appimage)
      --install-dir <dir>   macOS: app folder (default /Applications, or
                            ~/Applications when /Applications is not writable)
                            Linux AppImage: folder for atpage.AppImage
                            (default ~/.local/share/atpage)
      --purge               With --uninstall: delete settings, sessions and caches
  -y, --yes                 Do not ask for confirmation (closes a running atpage)
      --force               Reinstall the same version, or allow a downgrade
  -n, --dry-run             Show what would be done without changing anything
  -h, --help                Show this help
      --script-version      Print the script version

Environment:
  GITHUB_TOKEN              Optional token for GitHub API calls (rate limits)
  NO_COLOR                  Disable colored output

Examples:
  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sh
  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sh -s -- --update
  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sh -s -- --version 0.1.0
  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sh -s -- --format appimage
  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sh -s -- --troubleshoot
  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sh -s -- --uninstall --purge
EOF
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

has() { command -v "$1" >/dev/null 2>&1; }

# True when any of the given paths (usually unquoted globs) exists.
any_exists() {
  for f in "$@"; do
    if [ -e "$f" ]; then return 0; fi
  done
  return 1
}

# Runs a command, or only prints it with --dry-run.
run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '%s[dry-run]%s %s\n' "$C_D" "$C_0" "$*" >&2
  else
    "$@"
  fi
}

as_root() {
  if [ "$(id -u)" = 0 ]; then
    run "$@"
  elif has sudo; then
    run sudo "$@"
  elif has doas; then
    run doas "$@"
  else
    die "root privileges are needed for: $* (install sudo, or run as root)"
  fi
}

# Runs a command as root only when the directory is not writable by the user.
in_dir() {
  dir=$1; shift
  if [ -w "$dir" ]; then run "$@"; else as_root "$@"; fi
}

tty_available() { ( : </dev/tty ) 2>/dev/null; }

# confirm <question> <default y|n>. --yes answers yes; without a terminal the default wins.
confirm() {
  [ "$YES" = 1 ] && return 0
  if ! tty_available; then [ "$2" = y ]; return; fi
  if [ "$2" = y ]; then hint="[Y/n]"; else hint="[y/N]"; fi
  printf '%s %s ' "$1" "$hint" >/dev/tty
  ans=""
  read -r ans </dev/tty || ans=""
  case $ans in
    [Yy]*) return 0 ;;
    [Nn]*) return 1 ;;
    "") [ "$2" = y ] ;;
    *) return 1 ;;
  esac
}

cleanup() {
  if [ -n "$TMP_DIR" ]; then rm -rf "$TMP_DIR"; fi
}

make_tmp() {
  [ -n "$TMP_DIR" ] && return 0
  TMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t atpage)
  # Readable by apt's sandbox user when it installs a local .deb.
  chmod 755 "$TMP_DIR"
  REL_JSON="$TMP_DIR/release.json"
}

# Prints -1, 0 or 1 comparing X.Y.Z[-N] versions (a pre-release sorts before its release).
vercmp() {
  awk -v a="$1" -v b="$2" '
    function cmp(x, y,   xp, yp, xa, ya, n, m, i, k) {
      xp = ""; yp = ""
      if ((i = index(x, "-")) > 0) { xp = substr(x, i + 1); x = substr(x, 1, i - 1) }
      if ((i = index(y, "-")) > 0) { yp = substr(y, i + 1); y = substr(y, 1, i - 1) }
      n = split(x, xa, "."); m = split(y, ya, ".")
      k = (n > m) ? n : m
      for (i = 1; i <= k; i++) {
        if ((xa[i] + 0) < (ya[i] + 0)) return -1
        if ((xa[i] + 0) > (ya[i] + 0)) return 1
      }
      if (xp == "" && yp == "") return 0
      if (xp == "") return 1
      if (yp == "") return -1
      if ((xp + 0) < (yp + 0)) return -1
      if ((xp + 0) > (yp + 0)) return 1
      return 0
    }
    BEGIN { print cmp(a, b) }'
}

normalize_version() {
  v=${1#v}
  case $v in
    "" | *[!0-9.-]* | .* | -*) die "invalid version '$1' (expected X.Y.Z or X.Y.Z-N)" ;;
  esac
  printf '%s\n' "$v"
}

sha256_of() {
  if has sha256sum; then sha256sum "$1" | awk '{print $1}'
  elif has shasum; then shasum -a 256 "$1" | awk '{print $1}'
  elif has openssl; then openssl dgst -sha256 "$1" | awk '{print $NF}'
  else return 1
  fi
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

require_fetcher() {
  has curl || has wget || die "curl or wget is required"
}

# GitHub REST API call (path relative to the repo) -> stdout.
api_get() {
  if has curl; then
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      curl -fsSL --retry 2 --connect-timeout 15 -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $GITHUB_TOKEN" "$API_URL$1"
    else
      curl -fsSL --retry 2 --connect-timeout 15 -H "Accept: application/vnd.github+json" "$API_URL$1"
    fi
  else
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      wget -qO- --header="Accept: application/vnd.github+json" \
        --header="Authorization: Bearer $GITHUB_TOKEN" "$API_URL$1"
    else
      wget -qO- --header="Accept: application/vnd.github+json" "$API_URL$1"
    fi
  fi
}

download() {
  if has curl; then
    if [ -t 2 ]; then
      curl -fL --retry 3 --connect-timeout 15 --progress-bar -o "$2" "$1"
    else
      curl -fsSL --retry 3 --connect-timeout 15 -o "$2" "$1"
    fi
  else
    wget -q -O "$2" "$1"
  fi
}

# Latest published (non-pre-release) version. The releases/latest redirect needs no API quota.
latest_version() {
  tag=""
  if has curl; then
    url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' --connect-timeout 15 "$GH_URL/releases/latest" 2>/dev/null) || url=""
    case $url in */releases/tag/*) tag=${url##*/releases/tag/} ;; esac
  fi
  if [ -z "$tag" ]; then
    tag=$(api_get /releases/latest 2>/dev/null | grep -o '"tag_name": *"[^"]*"' | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/') || tag=""
  fi
  [ -n "$tag" ] || die "could not determine the latest release of $REPO (network problem or no releases yet)"
  normalize_version "$tag"
}

resolve_version() {
  if [ "$VERSION_REQ" = latest ]; then latest_version; else normalize_version "$VERSION_REQ"; fi
}

# Caches the release metadata (asset names and digests); missing metadata is not fatal.
fetch_release_json() {
  make_tmp
  if ! api_get "/releases/tags/v$1" >"$REL_JSON" 2>/dev/null; then
    : >"$REL_JSON"
    warn "could not read release metadata from the GitHub API (rate limit?); checksum verification is skipped"
  fi
}

# Picks the release asset whose name ends with the suffix.
asset_by_suffix() {
  [ -s "$REL_JSON" ] || return 1
  name=$(grep -o '"browser_download_url": *"[^"]*"' "$REL_JSON" | sed 's/.*\/\([^/"]*\)"$/\1/' |
    awk -v s="$1" 'length($0) >= length(s) && substr($0, length($0) - length(s) + 1) == s { print; exit }')
  [ -n "$name" ] && printf '%s\n' "$name"
}

# SHA-256 digest GitHub recorded for an asset (empty when unknown).
asset_digest() {
  [ -s "$REL_JSON" ] || return 0
  tr -d '\r\n' <"$REL_JSON" | awk -v n="$1" '{
    gsub(/" *: *"/, "\":\"")
    k = split($0, parts, /"browser_download_url"/)
    for (i = 1; i < k; i++) {
      if (index(parts[i], "\"name\":\"" n "\"") && match(parts[i], /"digest":"sha256:[0-9a-f]+"/)) {
        d = substr(parts[i], RSTART, RLENGTH); sub(/^.*sha256:/, "", d); sub(/"$/, "", d)
        print d; exit
      }
    }
  }'
}

verify_download() {
  expected=$(asset_digest "$2")
  if [ -z "$expected" ]; then
    warn "no published checksum for $2; skipping verification"
    return 0
  fi
  actual=$(sha256_of "$1") || { warn "no sha256 tool found; skipping verification"; return 0; }
  [ "$actual" = "$expected" ] || die "checksum mismatch for $2 (expected $expected, got $actual); the download is corrupted or was tampered with"
  ok "checksum verified (sha256 $actual)"
}

# ---------------------------------------------------------------------------
# Platform
# ---------------------------------------------------------------------------

detect_platform() {
  case $(uname -s) in
    Linux) OS=linux ;;
    Darwin) OS=macos ;;
    MINGW* | MSYS* | CYGWIN*)
      die "on Windows use PowerShell: irm https://raw.githubusercontent.com/$REPO/main/install.ps1 | iex" ;;
    *) die "unsupported OS: $(uname -s) (atpage desktop builds exist for Linux, macOS and Windows)" ;;
  esac
  case $(uname -m) in
    x86_64 | amd64) ARCH=x64 ;;
    aarch64 | arm64) ARCH=arm64 ;;
    *) die "unsupported CPU architecture: $(uname -m) (builds exist for x86_64 and arm64)" ;;
  esac
  # An x86_64 shell under Rosetta on Apple silicon still gets the native app.
  if [ "$OS" = macos ] && [ "$ARCH" = x64 ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
    ARCH=arm64
  fi

  DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
  APPS_DIR="$DATA_HOME/applications"
  ICON_DIR="$DATA_HOME/icons/hicolor/128x128/apps"
  BIN_DIR="$HOME/.local/bin"
  if [ "$OS" = linux ]; then
    AI_DIR="${INSTALL_DIR:-$DATA_HOME/atpage}"
    AI_FILE="$AI_DIR/$APP_NAME.AppImage"
  fi
}

# Asset name suffix and fallback file name for a format/version.
asset_suffix() {
  case $1 in
    deb) [ "$ARCH" = x64 ] && echo "_amd64.deb" || echo "_arm64.deb" ;;
    rpm) [ "$ARCH" = x64 ] && echo ".x86_64.rpm" || echo ".aarch64.rpm" ;;
    appimage) [ "$ARCH" = x64 ] && echo "_amd64.AppImage" || echo "_aarch64.AppImage" ;;
    app) [ "$ARCH" = x64 ] && echo "_x64.app.tar.gz" || echo "_aarch64.app.tar.gz" ;;
    dmg) [ "$ARCH" = x64 ] && echo "_x64.dmg" || echo "_aarch64.dmg" ;;
  esac
}

asset_fallback_name() {
  case $1 in
    rpm) echo "$PKG_NAME-$2-1$(asset_suffix rpm)" ;;
    *) echo "${APP_NAME}_$2$(asset_suffix "$1")" ;;
  esac
}

validate_format() {
  [ -z "$FORMAT" ] && return 0
  FORMAT=$(printf '%s' "$FORMAT" | tr 'A-Z' 'a-z')
  case "$OS:$FORMAT" in
    linux:deb | linux:rpm | linux:appimage | macos:app | macos:dmg) ;;
    *) die "format '$FORMAT' is not available on $OS (Linux: deb, rpm, appimage; macOS: app, dmg)" ;;
  esac
}

# Default Linux format: the native package when the package manager can install it.
auto_format() {
  if [ "$OS" = macos ]; then echo app; return; fi
  if has apt-get && has dpkg; then echo deb
  elif has rpm && { has dnf || has yum || has zypper; }; then echo rpm
  else echo appimage
  fi
}

# ---------------------------------------------------------------------------
# Installed state
# ---------------------------------------------------------------------------

deb_version() {
  has dpkg-query || return 0
  dpkg-query -W -f='${Status} ${Version}\n' "$PKG_NAME" 2>/dev/null | awk '$3 == "installed" { print $4 }'
}

rpm_version() {
  has rpm || return 0
  v=$(rpm -q --qf '%{VERSION}\n' "$PKG_NAME" 2>/dev/null) || return 0
  printf '%s\n' "$v" | head -n 1 | tr '~' '-'
}

appimage_version() {
  [ -f "$AI_FILE" ] || return 0
  if [ -s "$AI_DIR/version" ]; then cat "$AI_DIR/version"; else echo unknown; fi
}

mac_app_path() {
  for d in "$INSTALL_DIR" /Applications "$HOME/Applications"; do
    [ -n "$d" ] && [ -d "$d/$APP_NAME.app" ] && { printf '%s\n' "$d/$APP_NAME.app"; return 0; }
  done
  return 0
}

mac_app_version() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null ||
    defaults read "$1/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo unknown
}

# Lists installations as "format version location" lines.
list_installs() {
  if [ "$OS" = macos ]; then
    p=$(mac_app_path)
    [ -n "$p" ] && printf 'app %s %s\n' "$(mac_app_version "$p")" "$p"
  else
    v=$(deb_version); [ -n "$v" ] && printf 'deb %s %s\n' "$v" "/usr/bin/$BIN_NAME"
    v=$(rpm_version); [ -n "$v" ] && printf 'rpm %s %s\n' "$v" "/usr/bin/$BIN_NAME"
    v=$(appimage_version); [ -n "$v" ] && printf 'appimage %s %s\n' "$v" "$AI_FILE"
  fi
  return 0
}

# Sets CUR_FORMAT/CUR_VERSION/CUR_PATH from the first installation that matches --format (if any).
load_current() {
  CUR_FORMAT=""; CUR_VERSION=""; CUR_PATH=""
  installs=$(list_installs)
  [ -n "$installs" ] || return 0
  want=$FORMAT
  [ "$want" = dmg ] && want=app
  line=""
  if [ -n "$want" ]; then
    line=$(printf '%s\n' "$installs" | awk -v f="$want" '$1 == f { print; exit }')
  else
    line=$(printf '%s\n' "$installs" | head -n 1)
    if [ "$(printf '%s\n' "$installs" | wc -l)" -gt 1 ]; then
      warn "several installations found; using the $(echo "$line" | cut -d' ' -f1) one (choose with --format):"
      printf '%s\n' "$installs" | sed 's/^/    /' >&2
    fi
  fi
  [ -n "$line" ] || return 0
  CUR_FORMAT=$(echo "$line" | cut -d' ' -f1)
  CUR_VERSION=$(echo "$line" | cut -d' ' -f2)
  CUR_PATH=$(echo "$line" | cut -d' ' -f3-)
}

running_pid() {
  if [ "$OS" = macos ]; then
    pgrep -f "$APP_NAME.app/Contents/MacOS/" 2>/dev/null | head -n 1
  else
    pgrep -x "$BIN_NAME" 2>/dev/null | head -n 1
  fi
}

is_running() {
  if [ "$OS" = macos ]; then
    pgrep -f "$APP_NAME.app/Contents/MacOS/" >/dev/null 2>&1
  else
    pgrep -x "$BIN_NAME" >/dev/null 2>&1
  fi
}

# Closes a running atpage before files are replaced.
stop_running() {
  is_running || return 0
  [ "$DRY_RUN" = 1 ] && { info "atpage is running; it would be closed"; return 0; }
  confirm "atpage is running. Close it now?" y || die "close atpage and run the script again"
  info "closing atpage"
  if [ "$OS" = macos ]; then
    osascript -e "tell application id \"$IDENTIFIER\" to quit" >/dev/null 2>&1 || true
  else
    pkill -TERM -x "$BIN_NAME" 2>/dev/null || true
  fi
  i=0
  while is_running && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
  if is_running; then
    if [ "$OS" = macos ]; then pkill -f "$APP_NAME.app/Contents/MacOS/" 2>/dev/null || true
    else pkill -KILL -x "$BIN_NAME" 2>/dev/null || true
    fi
    sleep 1
  fi
}

# ---------------------------------------------------------------------------
# Linux desktop integration
# ---------------------------------------------------------------------------

refresh_desktop_db() {
  if has update-desktop-database; then run update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true; fi
  if has gtk-update-icon-cache && [ -d "$DATA_HOME/icons/hicolor" ]; then
    run gtk-update-icon-cache -q -t "$DATA_HOME/icons/hicolor" >/dev/null 2>&1 || true
  fi
}

# The app registers "<binary>-handler.desktop" for app.atpage:// at runtime. Remove it when
# it points at a binary that no longer exists (e.g. an AppImage moved or deleted), which
# breaks browser sign-in.
handler_file() { printf '%s\n' "$APPS_DIR/$BIN_NAME-handler.desktop"; }

handler_exec() {
  sed -n 's/^Exec="\{0,1\}\([^"]*\)"\{0,1\}.*%u.*$/\1/p' "$1" 2>/dev/null | head -n 1 | sed 's/ *$//'
}

clean_stale_handler() {
  f=$(handler_file)
  [ -f "$f" ] || return 0
  target=$(handler_exec "$f")
  if [ -z "$target" ] || [ ! -e "$target" ]; then
    info "removing stale sign-in handler $f (points to ${target:-nothing})"
    run rm -f "$f"
  fi
}

register_scheme() {
  if has xdg-mime; then
    run xdg-mime default "$1" "x-scheme-handler/$SCHEME" >/dev/null 2>&1 ||
      warn "xdg-mime could not register $1 for $SCHEME:// links"
  else
    warn "xdg-mime not found (package xdg-utils): $SCHEME:// sign-in links may not open atpage"
  fi
}

remove_scheme_defaults() {
  for f in "${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list" "$APPS_DIR/mimeapps.list"; do
    [ -f "$f" ] || continue
    grep -q "^x-scheme-handler/$SCHEME=" "$f" || continue
    if [ "$DRY_RUN" = 1 ]; then
      run "remove x-scheme-handler/$SCHEME from $f"
    else
      grep -v "^x-scheme-handler/$SCHEME=" "$f" >"$f.atpage-tmp" || true
      mv -f "$f.atpage-tmp" "$f"
    fi
  done
}

has_fuse2() {
  if has ldconfig; then ldconfig -p 2>/dev/null | grep -q 'libfuse\.so\.2' && return 0; fi
  [ -x /sbin/ldconfig ] && /sbin/ldconfig -p 2>/dev/null | grep -q 'libfuse\.so\.2' && return 0
  any_exists /lib*/libfuse.so.2* /usr/lib*/libfuse.so.2* /lib/*/libfuse.so.2* /usr/lib/*/libfuse.so.2*
}

fuse_hint() {
  if has apt-get; then echo "sudo apt install libfuse2   (Ubuntu 24.04+: libfuse2t64)"
  elif has dnf; then echo "sudo dnf install fuse fuse-libs"
  elif has zypper; then echo "sudo zypper install libfuse2"
  elif has pacman; then echo "sudo pacman -S fuse2"
  else echo "install FUSE 2 (libfuse.so.2) with your package manager"
  fi
}

# ---------------------------------------------------------------------------
# Linux formats
# ---------------------------------------------------------------------------

# install_deb <file> <mode: install|reinstall|downgrade>
install_deb() {
  if has apt-get; then
    case $2 in
      reinstall) as_root apt-get install -y --reinstall "$1" ;;
      downgrade) as_root apt-get install -y --allow-downgrades "$1" ;;
      *) as_root apt-get install -y "$1" ;;
    esac
  else
    as_root dpkg -i "$1" || die "dpkg could not install the package (missing dependencies: libwebkit2gtk-4.1-0, libgtk-3-0)"
  fi
}

install_rpm() {
  if has dnf; then
    case $2 in
      reinstall) as_root dnf reinstall -y "$1" ;;
      downgrade) as_root dnf downgrade -y "$1" ;;
      *) as_root dnf install -y "$1" ;;
    esac
  elif has zypper; then
    case $2 in
      reinstall) as_root zypper --non-interactive install --allow-unsigned-rpm --force "$1" ;;
      downgrade) as_root zypper --non-interactive install --allow-unsigned-rpm --oldpackage "$1" ;;
      *) as_root zypper --non-interactive install --allow-unsigned-rpm "$1" ;;
    esac
  elif has yum; then
    case $2 in
      reinstall) as_root yum reinstall -y "$1" ;;
      downgrade) as_root yum downgrade -y "$1" ;;
      *) as_root yum install -y "$1" ;;
    esac
  else
    case $2 in
      reinstall) as_root rpm -Uvh --replacepkgs "$1" ;;
      downgrade) as_root rpm -Uvh --oldpackage "$1" ;;
      *) as_root rpm -Uvh "$1" ;;
    esac
  fi
}

install_appimage() {
  file=$1; version=$2
  run mkdir -p "$AI_DIR" "$BIN_DIR" "$APPS_DIR" "$ICON_DIR"
  # Copy then rename, so a running AppImage is replaced atomically.
  run cp "$file" "$AI_FILE.new"
  run chmod 755 "$AI_FILE.new"
  run mv -f "$AI_FILE.new" "$AI_FILE"
  if [ "$DRY_RUN" = 0 ]; then printf '%s\n' "$version" >"$AI_DIR/version"; fi

  # Icon: extracted from the AppImage (works without FUSE).
  if [ "$DRY_RUN" = 0 ]; then
    ex="$TMP_DIR/extract"
    mkdir -p "$ex"
    (cd "$ex" && "$AI_FILE" --appimage-extract "usr/share/icons/hicolor/128x128/apps/*.png" >/dev/null 2>&1) || true
    (cd "$ex" && "$AI_FILE" --appimage-extract ".DirIcon" >/dev/null 2>&1) || true
    icon=""
    for c in "$ex/squashfs-root/usr/share/icons/hicolor/128x128/apps/$BIN_NAME.png" \
      "$ex/squashfs-root/$BIN_NAME.png" "$ex/squashfs-root/.DirIcon"; do
      if [ -f "$c" ]; then icon=$c; break; fi
    done
    if [ -n "$icon" ]; then cp -L "$icon" "$ICON_DIR/$BIN_NAME.png"; else warn "could not extract the app icon"; fi
  fi

  desktop="$APPS_DIR/$APP_NAME.desktop"
  if [ "$DRY_RUN" = 1 ]; then
    run "write $desktop"
  else
    cat >"$desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$APP_NAME
Comment=AT Protocol client
Exec="$AI_FILE" %u
Icon=$BIN_NAME
Terminal=false
Categories=Network;
StartupWMClass=$BIN_NAME
MimeType=x-scheme-handler/$SCHEME;
EOF
  fi
  run ln -sf "$AI_FILE" "$BIN_DIR/$APP_NAME"

  clean_stale_handler
  refresh_desktop_db
  register_scheme "$APP_NAME.desktop"

  has_fuse2 || warn "FUSE 2 (libfuse.so.2) not found; AppImages need it to start: $(fuse_hint)"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR is not on your PATH; start atpage from the app menu or with $AI_FILE" ;;
  esac
}

uninstall_linux() {
  fmt=$1
  case $fmt in
    deb)
      if has apt-get; then as_root apt-get remove -y "$PKG_NAME"; else as_root dpkg -r "$PKG_NAME"; fi ;;
    rpm)
      if has dnf; then as_root dnf remove -y "$PKG_NAME"
      elif has zypper; then as_root zypper --non-interactive remove "$PKG_NAME"
      elif has yum; then as_root yum remove -y "$PKG_NAME"
      else as_root rpm -e "$PKG_NAME"
      fi ;;
    appimage)
      run rm -f "$AI_FILE" "$AI_FILE.new" "$AI_DIR/version" "$APPS_DIR/$APP_NAME.desktop" "$ICON_DIR/$BIN_NAME.png"
      if [ -L "$BIN_DIR/$APP_NAME" ] && [ "$(readlink "$BIN_DIR/$APP_NAME")" = "$AI_FILE" ]; then
        run rm -f "$BIN_DIR/$APP_NAME"
      fi
      if [ -d "$AI_DIR" ] && [ -z "$(ls -A "$AI_DIR" 2>/dev/null)" ]; then run rmdir "$AI_DIR"; fi ;;
  esac
}

# ---------------------------------------------------------------------------
# macOS
# ---------------------------------------------------------------------------

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

mac_target_dir() {
  if [ -n "$CUR_PATH" ]; then dirname "$CUR_PATH"
  elif [ -n "$INSTALL_DIR" ]; then printf '%s\n' "$INSTALL_DIR"
  elif [ -w /Applications ]; then echo /Applications
  else echo "$HOME/Applications"
  fi
}

mac_register() {
  run xattr -dr com.apple.quarantine "$1" 2>/dev/null || true
  if [ -x "$LSREGISTER" ]; then run "$LSREGISTER" -f "$1" >/dev/null 2>&1 || true; fi
}

install_mac() {
  file=$1; fmt=$2
  dir=$(mac_target_dir)
  dest="$dir/$APP_NAME.app"
  stage="$TMP_DIR/stage"
  mkdir -p "$stage"
  if [ "$fmt" = dmg ]; then
    mnt="$TMP_DIR/mnt"
    mkdir -p "$mnt"
    hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$file" >/dev/null || die "could not mount $file"
    ditto "$mnt/$APP_NAME.app" "$stage/$APP_NAME.app" || { hdiutil detach "$mnt" -quiet || true; die "could not copy the app from the disk image"; }
    hdiutil detach "$mnt" -quiet || hdiutil detach "$mnt" -force -quiet || true
  else
    tar -xzf "$file" -C "$stage" || die "could not extract $file"
  fi
  [ -d "$stage/$APP_NAME.app" ] || die "the download does not contain $APP_NAME.app"
  xattr -dr com.apple.quarantine "$stage/$APP_NAME.app" 2>/dev/null || true

  if [ ! -d "$dir" ]; then
    case $dir in "$HOME"/*) run mkdir -p "$dir" ;; *) as_root mkdir -p "$dir" ;; esac
  fi
  backup=""
  if [ -d "$dest" ]; then
    backup="$dir/.$APP_NAME.app.old.$$"
    in_dir "$dir" mv "$dest" "$backup"
  fi
  if ! in_dir "$dir" ditto "$stage/$APP_NAME.app" "$dest"; then
    [ -n "$backup" ] && in_dir "$dir" mv "$backup" "$dest"
    die "could not install to $dest"
  fi
  [ -n "$backup" ] && in_dir "$dir" rm -rf "$backup"
  mac_register "$dest"
  INSTALLED_PATH=$dest
}

uninstall_mac() {
  p=$1
  if [ -x "$LSREGISTER" ]; then run "$LSREGISTER" -u "$p" >/dev/null 2>&1 || true; fi
  in_dir "$(dirname "$p")" rm -rf "$p"
}

# ---------------------------------------------------------------------------
# Data directories
# ---------------------------------------------------------------------------

data_dirs() {
  if [ "$OS" = macos ]; then
    printf '%s\n' \
      "$HOME/Library/Application Support/$IDENTIFIER" \
      "$HOME/Library/Caches/$IDENTIFIER" \
      "$HOME/Library/WebKit/$IDENTIFIER" \
      "$HOME/Library/HTTPStorages/$IDENTIFIER" \
      "$HOME/Library/Logs/$IDENTIFIER" \
      "$HOME/Library/Saved Application State/$IDENTIFIER.savedState" \
      "$HOME/Library/Preferences/$IDENTIFIER.plist"
  else
    printf '%s\n' \
      "$DATA_HOME/$IDENTIFIER" \
      "${XDG_CONFIG_HOME:-$HOME/.config}/$IDENTIFIER" \
      "${XDG_CACHE_HOME:-$HOME/.cache}/$IDENTIFIER"
  fi
}

existing_data_dirs() {
  data_dirs | while IFS= read -r p; do
    if [ -e "$p" ]; then printf '%s\n' "$p"; fi
  done
}

purge_data() {
  existing=$(existing_data_dirs)
  if [ -z "$existing" ]; then info "no local app data found"; return 0; fi
  say "Local app data (settings, sign-in sessions, caches):"
  printf '%s\n' "$existing" | sed 's/^/    /' >&2
  say "Your posts and account live on your PDS and are not affected."
  if [ "$DRY_RUN" = 0 ] && ! confirm "Delete this data?" n; then
    info "kept local app data"
    return 0
  fi
  printf '%s\n' "$existing" | while IFS= read -r p; do run rm -rf "$p"; done
  ok "local app data removed"
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

# Downloads, verifies and installs a version. mode: install|upgrade|reinstall|downgrade
install_version() {
  version=$1; fmt=$2; mode=$3
  make_tmp
  fetch_release_json "$version"
  suffix=$(asset_suffix "$fmt")
  name=$(asset_by_suffix "$suffix") || name=$(asset_fallback_name "$fmt" "$version")
  url="$GH_URL/releases/download/v$version/$name"

  info "atpage $version ($fmt, $OS $ARCH) — $mode"
  if [ "$DRY_RUN" = 1 ]; then
    say "  download: $url"
    case $fmt in
      app | dmg) say "  install to: $(mac_target_dir)/$APP_NAME.app" ;;
      appimage) say "  install to: $AI_FILE (desktop entry, icon, $BIN_DIR/$APP_NAME)" ;;
      deb | rpm) say "  install with the system package manager (needs sudo)" ;;
    esac
    stop_running
    return 0
  fi

  file="$TMP_DIR/$name"
  info "downloading $name"
  download "$url" "$file" || die "download failed: $url (does version $version exist? see --list)"
  verify_download "$file" "$name"

  stop_running
  pkg_mode=$mode
  [ "$pkg_mode" = upgrade ] && pkg_mode=install
  INSTALLED_PATH=""
  case $fmt in
    deb) install_deb "$file" "$pkg_mode"; INSTALLED_PATH="/usr/bin/$BIN_NAME" ;;
    rpm) install_rpm "$file" "$pkg_mode"; INSTALLED_PATH="/usr/bin/$BIN_NAME" ;;
    appimage) install_appimage "$file" "$version"; INSTALLED_PATH=$AI_FILE ;;
    app | dmg) install_mac "$file" "$fmt" ;;
  esac
  if [ "$OS" = linux ] && [ "$fmt" != appimage ]; then
    clean_stale_handler
    refresh_desktop_db
    register_scheme "$APP_NAME.desktop"
  fi

  ok "atpage $version installed ($INSTALLED_PATH)"
  if [ "$OS" = macos ]; then
    say "  Open it from Launchpad / Applications, or run: open -a \"$INSTALLED_PATH\""
  else
    say "  Open it from your app menu, or run: $( [ "$fmt" = appimage ] && echo "$APP_NAME" || echo "$BIN_NAME")"
  fi
  if [ "$fmt" = appimage ]; then
    warn "The AppImage has no H.264 video decoder, so most videos won't play. For video, install the .deb or .rpm package (--format deb / --format rpm)."
  fi
}

action_install() {
  load_current
  target=$(resolve_version)
  fmt=${FORMAT:-${CUR_FORMAT:-$(auto_format)}}
  [ "$OS" = macos ] && [ -z "$FORMAT" ] && fmt=app

  if [ -n "$CUR_VERSION" ]; then
    c=$(vercmp "$target" "$CUR_VERSION")
    if [ "$CUR_VERSION" = unknown ]; then
      install_version "$target" "$fmt" reinstall
    elif [ "$c" = 0 ] && [ "$FORCE" = 0 ]; then
      ok "atpage $CUR_VERSION is already installed ($CUR_FORMAT, $CUR_PATH)"
      say "  To reinstall it, use --repair (or --force)."
    elif [ "$c" = 0 ]; then
      install_version "$target" "$fmt" reinstall
    elif [ "$c" = 1 ]; then
      info "atpage $CUR_VERSION is installed; updating to $target"
      install_version "$target" "$fmt" upgrade
    elif [ "$FORCE" = 1 ]; then
      install_version "$target" "$fmt" downgrade
    else
      die "atpage $CUR_VERSION is newer than $target; pass --force to downgrade"
    fi
  else
    install_version "$target" "$fmt" install
  fi
}

action_update() {
  load_current
  if [ -z "$CUR_VERSION" ]; then
    info "atpage is not installed; installing it"
    action_install
    return
  fi
  target=$(resolve_version)
  fmt=${FORMAT:-$CUR_FORMAT}
  [ "$OS" = macos ] && [ -z "$FORMAT" ] && fmt=app
  if [ "$CUR_VERSION" = unknown ]; then
    install_version "$target" "$fmt" reinstall
    return
  fi
  c=$(vercmp "$target" "$CUR_VERSION")
  if [ "$c" = 1 ]; then
    info "updating atpage $CUR_VERSION -> $target"
    install_version "$target" "$fmt" upgrade
  elif [ "$c" = 0 ]; then
    if [ "$FORCE" = 1 ]; then install_version "$target" "$fmt" reinstall
    else ok "atpage $CUR_VERSION is up to date"
    fi
  elif [ "$FORCE" = 1 ]; then
    info "downgrading atpage $CUR_VERSION -> $target"
    install_version "$target" "$fmt" downgrade
  else
    die "installed atpage $CUR_VERSION is newer than $target; pass --force to downgrade"
  fi
}

action_repair() {
  load_current
  if [ -z "$CUR_VERSION" ]; then
    warn "atpage is not installed; installing it"
    action_install
    return
  fi
  if [ "$VERSION_REQ" != latest ]; then target=$(normalize_version "$VERSION_REQ")
  elif [ "$CUR_VERSION" = unknown ]; then target=$(latest_version)
  else target=$CUR_VERSION
  fi
  fmt=${FORMAT:-$CUR_FORMAT}
  [ "$OS" = macos ] && [ -z "$FORMAT" ] && fmt=app
  info "repairing atpage $CUR_VERSION ($CUR_FORMAT)"
  install_version "$target" "$fmt" reinstall
  if [ "$OS" = linux ]; then
    say "  Desktop entry and $SCHEME:// sign-in handler re-registered."
  fi
  say "  Still having problems? Run with --troubleshoot."
}

action_uninstall() {
  installs=$(list_installs)
  if [ -n "$FORMAT" ]; then
    want=$FORMAT; [ "$want" = dmg ] && want=app
    installs=$(printf '%s\n' "$installs" | awk -v f="$want" '$1 == f')
  fi
  if [ -z "$installs" ]; then
    info "atpage is not installed"
  else
    say "Removing:"
    printf '%s\n' "$installs" | sed 's/^/    /' >&2
    if [ "$DRY_RUN" = 0 ]; then confirm "Uninstall atpage?" y || die "cancelled"; fi
    stop_running
    printf '%s\n' "$installs" | while read -r fmt _ path; do
      if [ "$OS" = macos ]; then uninstall_mac "$path"; else uninstall_linux "$fmt"; fi
    done
    ok "atpage uninstalled"
  fi
  if [ "$OS" = linux ] && [ -z "$(list_installs)" ]; then
    run rm -f "$(handler_file)"
    remove_scheme_defaults
    refresh_desktop_db
  fi
  if [ "$PURGE" = 1 ]; then
    purge_data
  elif [ -n "$(existing_data_dirs)" ]; then
    say "  Local app data was kept; add --purge to delete it."
  fi
}

action_check() {
  installs=$(list_installs)
  latest=$(latest_version)
  if [ -z "$installs" ]; then
    say "installed: none"
    say "latest:    $latest"
    say "Install with: curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sh"
    return 0
  fi
  printf '%s\n' "$installs" | while read -r fmt v path; do
    say "installed: $v ($fmt, $path)"
  done
  say "latest:    $latest"
  load_current
  if [ "$CUR_VERSION" = unknown ] || [ "$(vercmp "$latest" "$CUR_VERSION")" = 1 ]; then
    say "${C_Y}An update is available.${C_0} Update with: curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sh -s -- --update"
  else
    ok "up to date"
  fi
}

action_list() {
  json=$(api_get "/releases?per_page=30") || die "could not list releases (GitHub API unreachable or rate-limited; set GITHUB_TOKEN)"
  installed=$(list_installs | awk '{print $2}' | head -n 1)
  printf '%s\n' "$json" | tr -d '\r\n' | awk '{
    gsub(/" *: *"/, "\":\""); gsub(/" *: */, "\":")
    k = split($0, parts, /"tag_name":"/)
    for (i = 2; i <= k; i++) {
      tag = substr(parts[i], 1, index(parts[i], "\"") - 1)
      pre = (index(parts[i], "\"prerelease\":true") > 0) ? " (pre-release)" : ""
      date = ""
      if (match(parts[i], /"published_at":"[0-9-]+/)) date = substr(parts[i], RSTART + 16, 10)
      print tag "\t" date pre
    }
  }' | while IFS="$(printf '\t')" read -r tag rest; do
    mark=""
    [ "${tag#v}" = "$installed" ] && mark="  <- installed"
    printf '%-14s %s%s\n' "$tag" "$rest" "$mark"
  done
}

# ---------------------------------------------------------------------------
# Troubleshooting
# ---------------------------------------------------------------------------

check_url() {
  if has curl; then curl -fsS -o /dev/null --connect-timeout 10 --max-time 20 "$1" 2>/dev/null
  else wget -q --spider --timeout=20 "$1" 2>/dev/null
  fi
}

lib_present() {
  { has ldconfig && ldconfig -p 2>/dev/null; } | grep -q "$1" && return 0
  [ -x /sbin/ldconfig ] && /sbin/ldconfig -p 2>/dev/null | grep -q "$1" && return 0
  any_exists /usr/lib*/"$1"* /usr/lib/*/"$1"* /lib/*/"$1"*
}

gst_plugin_present() {
  any_exists /usr/lib*/gstreamer-1.0/"$1" /usr/lib/*/gstreamer-1.0/"$1"
}

action_troubleshoot() {
  printf '%satpage troubleshooting%s (script %s, %s)\n' "$C_B" "$C_0" "$SCRIPT_VERSION" "$(date -u '+%Y-%m-%d %H:%M UTC')"

  section "System"
  if [ "$OS" = macos ]; then
    chk_info "macOS $(sw_vers -productVersion 2>/dev/null) ($(uname -m)$( [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ] && echo ', shell under Rosetta'))"
    major=$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)
    if [ -n "$major" ] && [ "$major" -lt 11 ]; then chk_fail "atpage needs macOS 11 or newer"; fi
  else
    distro=$( (. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-$NAME}") || echo unknown)
    chk_info "$distro, kernel $(uname -r), $(uname -m)"
    chk_info "session: ${XDG_SESSION_TYPE:-unknown}, desktop: ${XDG_CURRENT_DESKTOP:-unknown}"
  fi
  chk_info "package format: ${FORMAT:-$(auto_format)} (auto-selected for this system)"

  section "Installation"
  installs=$(list_installs)
  latest=""
  latest=$( (latest_version) 2>/dev/null) || latest=""
  if [ -z "$installs" ]; then
    chk_warn "atpage is not installed"
  else
    n=$(printf '%s\n' "$installs" | wc -l | tr -d ' ')
    if [ "$n" -gt 1 ]; then chk_warn "$n installations found; keep one (--uninstall --format <format>)"; fi
    printf '%s\n' "$installs" | while read -r fmt v path; do
      if [ -e "$path" ]; then chk_ok "$fmt $v at $path"; else chk_fail "$fmt $v: $path is missing (run --repair)"; fi
      if [ -n "$latest" ] && { [ "$v" = unknown ] || [ "$(vercmp "$latest" "$v")" = 1 ]; }; then
        chk_warn "update available: $v -> $latest (run --update)"
      fi
    done
  fi
  [ -n "$latest" ] && chk_info "latest release: $latest"
  if is_running; then chk_info "atpage is running (pid $(running_pid))"; fi

  section "Network"
  for u in "https://github.com" "https://bsky.social/xrpc/_health" "https://atpage.app"; do
    if check_url "$u"; then chk_ok "reachable: $u"; else chk_fail "cannot reach $u (proxy, firewall or DNS?)"; fi
  done

  if [ "$OS" = linux ]; then
    section "Runtime libraries"
    native=0
    printf '%s\n' "$installs" | grep -qE '^(deb|rpm) ' && native=1
    for lib in libwebkit2gtk-4.1.so.0 libgtk-3.so.0 libsoup-3.0.so.0; do
      if lib_present "$lib"; then chk_ok "$lib"
      elif [ "$native" = 1 ]; then chk_fail "$lib missing (reinstall with --repair to pull dependencies)"
      else chk_info "$lib not found (bundled in the AppImage; needed for deb/rpm)"
      fi
    done
    if printf '%s\n' "$installs" | grep -q '^appimage '; then
      if has_fuse2; then chk_ok "FUSE 2 (AppImage)"; else chk_fail "FUSE 2 missing, the AppImage cannot start: $(fuse_hint)"; fi
    fi
    if [ "$native" = 1 ]; then
      if gst_plugin_present libgstlibav.so; then chk_ok "GStreamer libav (H.264 video)"
      else chk_warn "GStreamer libav missing: videos may not play (gstreamer1.0-libav / gstreamer1-plugin-libav)"; fi
      if gst_plugin_present libgstisomp4.so; then chk_ok "GStreamer good plugins (MP4)"
      else chk_warn "GStreamer good plugins missing: videos may not play (gstreamer1.0-plugins-good)"; fi
    fi
    if [ -e /proc/driver/nvidia/version ]; then
      chk_warn "NVIDIA driver: if the window is blank or white, start atpage with WEBKIT_DISABLE_DMABUF_RENDERER=1"
    fi

    section "Sign-in handler ($SCHEME://)"
    if has xdg-mime; then
      handler=$(xdg-mime query default "x-scheme-handler/$SCHEME" 2>/dev/null || true)
      if [ -z "$handler" ]; then chk_fail "no handler registered (run --repair)"
      else
        hpath=""
        for d in "$APPS_DIR" /usr/local/share/applications /usr/share/applications; do
          [ -f "$d/$handler" ] && { hpath="$d/$handler"; break; }
        done
        if [ -z "$hpath" ]; then chk_fail "handler $handler does not exist (run --repair)"
        else
          exe=$(sed -n 's/^Exec=//p' "$hpath" | head -n 1 | sed 's/^"\([^"]*\)".*/\1/; s/ .*//')
          case $exe in /*) ;; *) exe=$(command -v "$exe" 2>/dev/null || echo "$exe") ;; esac
          if [ -e "$exe" ]; then chk_ok "$handler -> $exe"; else chk_fail "$handler points to missing $exe (run --repair)"; fi
        fi
      fi
    else
      chk_fail "xdg-mime not found (install xdg-utils); browser sign-in cannot return to atpage"
    fi
    f=$(handler_file)
    if [ -f "$f" ]; then
      t=$(handler_exec "$f")
      if [ -n "$t" ] && [ -e "$t" ]; then chk_ok "runtime handler $f -> $t"; else chk_fail "stale runtime handler $f -> ${t:-?} (run --repair)"; fi
    fi
    case ":$PATH:" in
      *":$BIN_DIR:"*) ;;
      *)
        if printf '%s\n' "$installs" | grep -q '^appimage '; then
          chk_info "$BIN_DIR is not on PATH (only affects starting atpage from a terminal)"
        fi ;;
    esac
  else
    section "macOS"
    p=$(mac_app_path)
    if [ -n "$p" ]; then
      if xattr -p com.apple.quarantine "$p" >/dev/null 2>&1; then
        chk_fail "quarantine flag set: macOS may say the app is damaged (run --repair)"
      else
        chk_ok "no quarantine flag"
      fi
      appbin=$(defaults read "$p/Contents/Info" CFBundleExecutable 2>/dev/null || echo "$BIN_NAME")
      if [ "$ARCH" = arm64 ]; then want_arch=arm64; else want_arch=x86_64; fi
      if file "$p/Contents/MacOS/$appbin" 2>/dev/null | grep -q "$want_arch"; then
        chk_ok "binary matches this Mac ($want_arch)"
      elif [ -e "$p/Contents/MacOS/$appbin" ]; then
        chk_warn "binary architecture differs from this Mac; reinstall with --repair"
      fi
      chk_info "builds are not code-signed yet: if macOS blocks the app, right-click it -> Open"
    fi
  fi

  section "Local app data"
  existing_data_dirs | while IFS= read -r d; do
    chk_info "$(du -sh "$d" 2>/dev/null | cut -f1)	$d"
  done
  chk_info "a fresh start without reinstalling: --uninstall --purge, then install again"

  section "Help"
  say "  Report problems at $GH_URL/issues and include this output."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

parse_args() {
  while [ $# -gt 0 ]; do
    case $1 in
      -i | --install) ACTION=install ;;
      -u | --update | --upgrade) ACTION=update ;;
      --uninstall | --remove) ACTION=uninstall ;;
      -r | --repair | --reinstall) ACTION=repair ;;
      -t | --troubleshoot | --troubleshooting | --doctor) ACTION=troubleshoot ;;
      -c | --check) ACTION=check ;;
      -l | --list | --list-versions) ACTION=list ;;
      -v | --version | --target-version | --target)
        [ $# -ge 2 ] || die "$1 needs a version (e.g. 0.1.0 or latest)"
        VERSION_REQ=$2; shift ;;
      --version=* | --target-version=* | --target=*) VERSION_REQ=${1#*=} ;;
      -f | --format)
        [ $# -ge 2 ] || die "$1 needs a format"
        FORMAT=$2; shift ;;
      --format=*) FORMAT=${1#*=} ;;
      --install-dir)
        [ $# -ge 2 ] || die "$1 needs a directory"
        INSTALL_DIR=$2; shift ;;
      --install-dir=*) INSTALL_DIR=${1#*=} ;;
      --purge) PURGE=1 ;;
      -y | --yes) YES=1 ;;
      --force) FORCE=1 ;;
      -n | --dry-run) DRY_RUN=1 ;;
      -h | --help) usage; exit 0 ;;
      --script-version) echo "$SCRIPT_VERSION"; exit 0 ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
  done
  [ "$VERSION_REQ" = latest ] || [ "$VERSION_REQ" = "" ] || VERSION_REQ=$(normalize_version "$VERSION_REQ")
  [ -n "$VERSION_REQ" ] || VERSION_REQ=latest
  if [ -n "$INSTALL_DIR" ]; then
    case $INSTALL_DIR in /*) ;; *) INSTALL_DIR="$(pwd)/$INSTALL_DIR" ;; esac
    INSTALL_DIR=${INSTALL_DIR%/}
  fi
}

main() {
  setup_colors
  parse_args "$@"
  [ -n "${HOME:-}" ] || die "HOME is not set"
  detect_platform
  validate_format
  require_fetcher
  trap cleanup EXIT
  trap 'exit 130' INT TERM

  case $ACTION in
    install) action_install ;;
    update) action_update ;;
    repair) action_repair ;;
    uninstall) action_uninstall ;;
    check) action_check ;;
    list) action_list ;;
    troubleshoot) action_troubleshoot ;;
  esac
}

main "$@"
