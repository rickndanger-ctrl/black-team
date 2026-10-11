#!/bin/sh
# Offline, per-user install and rollback. No sudo and no model downloads.
set -eu
umask 077
prefix=${HOME}/.local
rollback=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix) [ "$#" -ge 2 ] || { echo '--prefix needs a directory' >&2; exit 2; }; prefix=$2; shift 2 ;;
    --rollback) rollback=true; shift ;;
    --help) printf '%s\n' 'Usage: ./install.sh [--prefix /absolute/directory] [--rollback]'; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
case "$prefix" in /*) ;; *) echo 'Use an absolute --prefix directory.' >&2; exit 2 ;; esac
case "$prefix" in *'
'*) echo 'The install prefix cannot contain a newline.' >&2; exit 2 ;; esac
mkdir -p "$prefix"
prefix=$(CDPATH= cd -- "$prefix" && pwd -P)
root=$prefix/share/black-team
launcher=$prefix/bin/black-team-desktop
desktop=$prefix/share/applications/black-team-desktop.desktop
mkdir -p "$root/releases"
lock=$root/.install-lock
if ! mkdir "$lock" 2>/dev/null; then
  echo 'Another install is running, or an interrupted install left .install-lock. Check before retrying.' >&2
  exit 1
fi
stage=''
cleanup() { [ -z "$stage" ] || rm -rf -- "$stage"; rm -f -- "$root/.current-new" "$root/.previous-new"; rmdir "$lock" 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
valid_link() {
  case "$1" in releases/*) case "${1#releases/}" in ''|*/*|*[!A-Za-z0-9.-]*) return 1 ;; esac ;; *) return 1 ;; esac
  [ -f "$root/$1/electron" ] && [ -f "$root/$1/RELEASE_VERSION" ]
}
current=''
if [ -L "$root/current" ]; then current=$(readlink "$root/current"); valid_link "$current" || { echo 'Current release link is invalid.' >&2; exit 1; }
elif [ -e "$root/current" ]; then echo 'Refusing to overwrite an unmanaged current directory.' >&2; exit 1; fi
if "$rollback"; then
  [ -n "$current" ] && [ -L "$root/previous" ] || { echo 'No previous release is available.' >&2; exit 1; }
  previous=$(readlink "$root/previous")
  valid_link "$previous" || { echo 'Previous release is invalid.' >&2; exit 1; }
  ln -s "$previous" "$root/.current-new"
  ln -s "$current" "$root/.previous-new"
  mv -Tf -- "$root/.previous-new" "$root/previous"
  mv -Tf -- "$root/.current-new" "$root/current"
  printf 'Rolled back to %s. Restart Black Team to use it. Your data was preserved.\n' "${previous#releases/}"
  exit 0
fi
source=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
for command in tar sha256sum readlink; do command -v "$command" >/dev/null || { printf 'Required command missing: %s\n' "$command" >&2; exit 1; }; done
[ -f "$source/VERSION" ] && [ -f "$source/SHA256SUMS" ] && [ -f "$source/payload.tar.gz" ] || { echo 'Extract the complete distribution before installing.' >&2; exit 1; }
version=$(cat "$source/VERSION")
case "$version" in ''|*[!A-Za-z0-9.-]*|.*) echo 'Invalid release version.' >&2; exit 1 ;; esac
for managed_file in "$launcher" "$desktop"; do
  if [ -e "$managed_file" ] || [ -L "$managed_file" ]; then
    if [ -L "$managed_file" ] || ! grep -q '^# black-team-managed-v1$' "$managed_file"; then
      printf 'Refusing to overwrite an unrelated file: %s\nChoose another --prefix.\n' "$managed_file" >&2; exit 1
    fi
  fi
done
if [ -e "$root/releases/$version" ]; then
  echo 'This release version is already installed. Use --rollback or a different versioned release.' >&2
  exit 1
fi
# Only the expected checksum entry is accepted; the sidecar checks corruption,
# not publisher authenticity. Obtain archives from a trusted release channel.
if [ "$(wc -l < "$source/SHA256SUMS")" -ne 1 ] || ! LC_ALL=C grep -Eq '^[a-f0-9]{64}  payload\.tar\.gz$' "$source/SHA256SUMS"; then
  echo 'Invalid payload checksum file.' >&2; exit 1
fi
(cd "$source" && sha256sum -c SHA256SUMS)
stage=$(mktemp -d "$root/releases/.staging-XXXXXX")
tar -tzf "$source/payload.tar.gz" | while IFS= read -r member; do
  case "$member" in /*|../*|*/../*|*/..|..) echo 'Unsafe archive path.' >&2; exit 1 ;; esac
done
tar -xzf "$source/payload.tar.gz" -C "$stage" --no-same-owner --no-same-permissions
[ -x "$stage/electron" ] && [ -f "$stage/resources/app/main.cjs" ] && [ -f "$stage/MANIFEST.json" ] || { echo 'The payload is incomplete.' >&2; exit 1; }
[ "$(cat "$stage/RELEASE_VERSION")" = "$version" ] || { echo 'Payload version mismatch.' >&2; exit 1; }
mv -- "$stage" "$root/releases/$version"
stage=''
mkdir -p "$prefix/bin" "$prefix/share/applications"
# Escape a filesystem path as one literal shell argument.
quoted_root=$(printf '%s' "$root" | sed "s/'/'\\\\''/g")
{
  printf '%s\n' '#!/bin/sh' '# black-team-managed-v1'
  printf "install_root='%s'\n" "$quoted_root"
  printf '%s\n' 'if [ "${1-}" = "--rollback" ]; then shift; exec "$install_root/manage.sh" --prefix "$(dirname "$(dirname "$install_root")")" --rollback "$@"; fi'
  printf '%s\n' 'exec "$install_root/current/electron" "$install_root/current/resources/app" "$@"'
} > "$launcher.tmp"
chmod 755 "$launcher.tmp"
mv -f -- "$launcher.tmp" "$launcher"
cp -- "$source/install.sh" "$root/manage.sh.tmp"
chmod 700 "$root/manage.sh.tmp"
mv -f -- "$root/manage.sh.tmp" "$root/manage.sh"
# Desktop Entry quoting includes percent field-code escaping.
desktop_launcher=$(printf '%s' "$launcher" | sed 's/\\/\\\\/g; s/"/\\"/g; s/`/\\`/g; s/\$/\\$/g; s/%/%%/g')
{
  printf '%s\n' '[Desktop Entry]' '# black-team-managed-v1' 'Type=Application' 'Name=Black Team' 'Comment=Private AI on your computer'
  printf 'Exec="%s"\n' "$desktop_launcher"
  printf 'Icon=%s/current/resources/app/dist/black-team-512.png\n' "$root"
  printf '%s\n' 'Terminal=false' 'Categories=Utility;' 'StartupWMClass=Black Team'
} > "$desktop.tmp"
chmod 644 "$desktop.tmp"
mv -f -- "$desktop.tmp" "$desktop"
if [ -n "$current" ]; then
  ln -s "$current" "$root/.previous-new"
  mv -Tf -- "$root/.previous-new" "$root/previous"
fi
ln -s "releases/$version" "$root/.current-new"
mv -Tf -- "$root/.current-new" "$root/current"
printf 'Installed Black Team %s.\nLaunch: %s\nRollback: %s --rollback\nYour application data is preserved separately.\n' "$version" "$launcher" "$launcher"
