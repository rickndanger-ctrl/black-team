#!/bin/sh
# Offline, per-user install and rollback. No sudo and no model downloads.
set -eu
umask 077
prefix=${HOME}/.local
rollback=false
action=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix) [ "$#" -ge 2 ] || { echo '--prefix needs a directory' >&2; exit 2; }; prefix=$2; shift 2 ;;
    --rollback) rollback=true; shift ;;
    --sandbox-status|--sandbox-help|--sandbox-profile|--enable-sandbox) action=${1#--}; shift ;;
    --help) printf '%s\n' 'Usage: ./install.sh [--prefix /absolute/directory] [--rollback | --sandbox-status | --sandbox-profile | --enable-sandbox]'; exit 0 ;;
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
# The window runs inside Chromium's sandbox, which needs unprivileged user namespaces.
# Ubuntu 24.04 and later deny those to programs without an AppArmor profile, so the
# window cannot start there until one profile is installed. That needs root once.
sysctl_root=${BLACK_TEAM_SYSCTL_ROOT:-/proc/sys}
profile_dir=${BLACK_TEAM_APPARMOR_DIR:-/etc/apparmor.d}
profile_name=black-team-$(printf '%s' "$root" | sha256sum | cut -c1-12)
setting() { cat "$sysctl_root/$1" 2>/dev/null || printf '%s\n' "$2"; }
sandbox_state() {
  helper=$root/current/chrome-sandbox
  if [ -u "$helper" ] && [ "$(stat -c %u "$helper" 2>/dev/null || echo 1)" = 0 ]; then echo ok
  elif [ "$(setting kernel/unprivileged_userns_clone 1)" = 0 ] || [ "$(setting user/max_user_namespaces 1)" = 0 ]; then echo disabled
  elif [ "$(setting kernel/apparmor_restrict_unprivileged_userns 0)" = 1 ] && [ ! -f "$profile_dir/$profile_name" ]; then echo apparmor
  else echo ok; fi
}
sandbox_profile() {
  case "$root" in *[!A-Za-z0-9._/+-]*) echo 'The install folder has characters an AppArmor profile cannot safely name. Install under a simpler --prefix, or see DISTRIBUTION.md.' >&2; return 1 ;; esac
  printf '%s\n' '# black-team-managed-v1' "# Lets Black Team's window use its own sandbox. Remove with:" "#   sudo apparmor_parser -R $profile_dir/$profile_name && sudo rm $profile_dir/$profile_name" 'abi <abi/4.0>,' 'include <tunables/global>' '' \
    "profile $profile_name $root/releases/*/electron flags=(unconfined) {" '  userns,' "  include if exists <local/$profile_name>" '}'
}
sandbox_help() {
  case "$1" in
    apparmor) printf '%s\n' '' 'Black Team cannot open its window on this system yet.' 'This system (Ubuntu 24.04 and later do this by default) blocks the sandbox the window runs in.' 'To allow it for Black Team only, run:' '' "  $launcher --enable-sandbox" '' 'That asks for your password once and installs one AppArmor profile. Do not use --no-sandbox.' ;;
    disabled) printf '%s\n' '' 'Black Team cannot open its window on this system yet.' 'Unprivileged user namespaces are turned off here, and the window sandbox needs them.' 'An administrator has to turn them on; see "Sandbox" in DISTRIBUTION.md. Do not use --no-sandbox.' ;;
  esac
}
case "$action" in
  sandbox-status) state=$(sandbox_state); echo "$state"; [ "$state" = ok ]; exit ;;
  sandbox-help) sandbox_help "$(sandbox_state)"; exit 0 ;;
  sandbox-profile) sandbox_profile; exit ;;
  enable-sandbox)
    state=$(sandbox_state)
    [ "$state" != ok ] || { echo 'The sandbox already works here. Nothing to do.'; exit 0; }
    [ "$state" = apparmor ] || { sandbox_help "$state" >&2; exit 1; }
    command -v sudo >/dev/null || { echo 'sudo is needed to install the AppArmor profile. Ask an administrator to install the output of --sandbox-profile.' >&2; exit 1; }
    draft=$(mktemp)
    trap 'rm -f -- "$draft"' EXIT HUP INT TERM
    sandbox_profile > "$draft"
    printf 'This installs the profile below as /etc/apparmor.d/%s and loads it.\nIt lets only this Black Team install create its sandbox.\n\n' "$profile_name"
    cat "$draft"; echo
    sudo install -o root -g root -m 644 "$draft" "/etc/apparmor.d/$profile_name"
    sudo apparmor_parser -r "/etc/apparmor.d/$profile_name"
    echo 'Done. Start Black Team again.'
    exit 0 ;;
esac
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
[ -x "$stage/electron" ] && [ -f "$stage/resources/app/main.cjs" ] && [ -x "$stage/resources/app/bin/black-team" ] && [ -f "$stage/MANIFEST.json" ] || { echo 'The payload is incomplete.' >&2; exit 1; }
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
  printf '%s\n' 'prefix=$(dirname "$(dirname "$install_root")")'
  printf '%s\n' 'if [ "${1-}" = "--enable-sandbox" ]; then exec "$install_root/manage.sh" --prefix "$prefix" --enable-sandbox; fi'
  # Where the sandbox is known to be blocked, stay behind the window so a failed start can be explained.
  printf '%s\n' 'if "$install_root/manage.sh" --prefix "$prefix" --sandbox-status >/dev/null 2>&1 || [ ! -x "$install_root/manage.sh" ]; then exec "$install_root/current/electron" "$install_root/current/resources/app" "$@"; fi'
  printf '%s\n' 'started=$(date +%s); code=0'
  printf '%s\n' '"$install_root/current/electron" "$install_root/current/resources/app" "$@" || code=$?'
  printf '%s\n' 'if [ "$code" -ne 0 ] && [ "$(( $(date +%s) - started ))" -lt 15 ]; then'
  printf '%s\n' '  help=$("$install_root/manage.sh" --prefix "$prefix" --sandbox-help)' '  printf "%s\n" "$help" >&2'
  printf '%s\n' '  if [ ! -t 2 ] && command -v notify-send >/dev/null 2>&1; then notify-send -a "Black Team" "Black Team cannot open its window yet" "$help" || true; fi'
  printf '%s\n' 'fi' 'exit "$code"'
} > "$launcher.tmp"
chmod 755 "$launcher.tmp"
mv -f -- "$launcher.tmp" "$launcher"
cp -- "$source/install.sh" "$root/manage.sh.tmp"
chmod 700 "$root/manage.sh.tmp"
mv -f -- "$root/manage.sh.tmp" "$root/manage.sh"
# Desktop Entry quoting includes percent field-code escaping.
desktop_launcher=$(printf '%s' "$launcher" | sed 's/\\/\\\\/g; s/"/\\"/g; s/`/\\`/g; s/\$/\\$/g; s/%/%%/g')
{
  printf '%s\n' '[Desktop Entry]' '# black-team-managed-v1' 'Type=Application' 'Name=Black Team Agent' 'Comment=Private AI on your computer'
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
# The terminal command, when its name is free: a link through "current", so an update or a rollback is followed. A file or link
# of that name that is not this one is left alone.
command_link=$prefix/bin/black-team
command_target=$root/current/resources/app/bin/black-team
command_note="Command: $command_link"
if [ -L "$command_link" ] && [ "$(readlink "$command_link")" = "$command_target" ]; then :
elif [ ! -e "$command_link" ] && [ ! -L "$command_link" ]; then ln -s "$command_target" "$command_link" || command_note="Command: $command_target"
else command_note="Command: $command_target ($command_link already exists and was left alone)"
fi
printf 'Installed Black Team Agent %s.\nLaunch: %s\n%s\nRollback: %s --rollback\nYour application data is preserved separately.\n' "$version" "$launcher" "$command_note" "$launcher"
sandbox_help "$(sandbox_state)"
