#!/bin/sh
# Krufter — Linux installer (#590 / JS13.2).
#
#   curl -fsSL https://raw.githubusercontent.com/KrufterApps/krufter-releases/main/install.sh | sh
#
# That URL carries neither a version nor a file name: publishing a release never
# changes what a visitor types. The script reads `latest.json` from the public
# mirror — the same source of truth as the application and the showcase — picks
# the package built for this distribution, **verifies its sha256** against the
# manifest, and only then installs it (or prints the exact command to run).
#
# This file is the source; the release job copies it to `main` of the public
# mirror, which never holds anything else (installers only).
#
# POSIX sh, no bashisms, no `jq`: the manifest is flattened and read with `sed`.
# Messages are English — a shell is not website chrome.
set -eu

MANIFEST_URL="${KRUFTER_RELEASE_MANIFEST_URL:-https://raw.githubusercontent.com/KrufterApps/krufter-releases/main/latest.json}"
RELEASES_URL='https://github.com/KrufterApps/krufter-releases/releases'
DRY_RUN=0

say() { printf '%s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'TEXT'
Krufter installer — installs the latest published release on Linux.

Usage: install.sh [--dry-run] [--help]

  --dry-run   resolve the package of the latest release and verify its sha256,
              then stop and print what would be installed (nothing is installed)
  --help      this text

Environment:
  KRUFTER_RELEASE_MANIFEST_URL   manifest to read (default: the public mirror).
                                 Handy to check a local manifest.
  KRUFTER_PKG_MANAGER            force the package manager instead of detecting
                                 it: `apt-get`, `dnf` or `yum`.

The package is downloaded from the public mirror and its sha256 is compared with
the manifest before anything is installed. Nothing runs as root without saying
so, and `--dry-run` shows everything without touching the system.
TEXT
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) fail "unknown option: $1 (try --help)" ;;
  esac
  shift
done

# --- what are we running on? -------------------------------------------------

os="$(uname -s)"
if [ "$os" != 'Linux' ]; then
  fail "this installer is for Linux (found $os) — packages for your system: $RELEASES_URL"
fi

arch="$(uname -m)"
case "$arch" in
  x86_64 | amd64) ;;
  *)
    # The published .deb name (`krufter_app-0.10.0-linux.deb`) carries no
    # architecture, so a non-x86_64 machine cannot be matched against the
    # manifest: refuse rather than install a package built for another one.
    fail "no installer for your architecture ($arch) — published packages target x86_64: $RELEASES_URL"
    ;;
esac

if [ -n "${KRUFTER_PKG_MANAGER:-}" ]; then
  pm="$KRUFTER_PKG_MANAGER"
elif command -v dnf >/dev/null 2>&1; then
  pm='dnf'
elif command -v yum >/dev/null 2>&1; then
  pm='yum'
elif command -v apt-get >/dev/null 2>&1; then
  pm='apt-get'
else
  fail "no supported package manager (apt-get, dnf or yum) — download the package yourself: $RELEASES_URL"
fi

case "$pm" in
  apt-get) asset_key='linux_deb' ;;
  dnf | yum) asset_key='linux_rpm' ;;
  *) fail "unsupported package manager: $pm (apt-get, dnf or yum)" ;;
esac

tmp=''
keep_tmp=0
cleanup() {
  if [ "$keep_tmp" = 0 ] && [ -n "$tmp" ]; then
    rm -rf "$tmp"
  fi
}
trap cleanup EXIT INT TERM

fetch() { # $1 = url, $2 = destination file
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$1"
  else
    fail 'neither curl nor wget is available'
  fi
}

# --- the latest release, as the mirror publishes it -------------------------

tmp="$(mktemp -d)"
say "→ release manifest: $MANIFEST_URL"
fetch "$MANIFEST_URL" "$tmp/latest.json" || fail "could not download the manifest: $MANIFEST_URL"

flat="$(tr -d '\n\r' <"$tmp/latest.json")"
field() { # $1 = key, $2 = field name — from the *first* value of that name
  printf '%s' "$flat" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*{[^}]*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}
published() { # $1 = key — non-empty when the manifest advertises it
  printf '%s' "$flat" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*{[^}]*}.*/yes/p"
}

version="$(printf '%s' "$flat" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
say "→ latest release: ${version:-unknown}"

if [ -z "$(published "$asset_key")" ]; then
  fail "no Linux package published for this distribution yet ($asset_key) — see $RELEASES_URL"
fi

name="$(field "$asset_key" name)"
url="$(field "$asset_key" url)"
expected="$(field "$asset_key" sha256)"
if [ -z "$name" ] || [ -z "$url" ] || [ -z "$expected" ]; then
  fail "incomplete manifest entry for $asset_key (name, url and sha256 are required)"
fi

# --- download, verify, and only then touch the system ------------------------

say "→ $name"
fetch "$url" "$tmp/$name" || fail "could not download the package: $url"

if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$tmp/$name")"
elif command -v shasum >/dev/null 2>&1; then
  actual="$(shasum -a 256 "$tmp/$name")"
else
  fail 'no sha256 tool (sha256sum or shasum) — refusing to install something unverified'
fi
actual="${actual%% *}"
[ "$actual" = "$expected" ] || fail "sha256 mismatch for $name: expected $expected, got $actual"
say "✓ sha256 $actual verified against the manifest"

install_cmd() { # $1 = package path
  case "$pm" in
    apt-get) printf 'apt-get install -y %s' "$1" ;;
    *) printf '%s install -y %s' "$pm" "$1" ;;
  esac
}

if [ "$DRY_RUN" = 1 ]; then
  say ''
  say 'dry run — nothing was installed. It would run:'
  say "  sudo $(install_cmd "$tmp/$name")"
  say '  (the verified file lives in a temporary directory, removed on exit)'
  exit 0
fi

if [ "$(id -u)" = 0 ]; then
  say "→ installing $name"
  "$pm" install -y "$tmp/$name" || fail "installation failed — retry it yourself: $(install_cmd "$tmp/$name")"
elif command -v sudo >/dev/null 2>&1; then
  say "→ installing $name (with sudo)"
  sudo "$pm" install -y "$tmp/$name" || fail "installation failed — retry it yourself: sudo $(install_cmd "$tmp/$name")"
else
  # Verified, and kept: the printed command has to stay runnable.
  keep_tmp=1
  say '→ no sudo available here: the package is downloaded and verified, install it as root with'
  say "  $(install_cmd "$tmp/$name")"
  say '  (or open it with your desktop package installer)'
  exit 0
fi

say "✓ Krufter $version installed — release notes: ${RELEASES_URL}/tag/v$version"
