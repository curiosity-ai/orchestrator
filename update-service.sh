#!/bin/sh
# Update the Curiosity Orchestrator that install-service.sh installed as a systemd service.
#
#   curl -fsSL https://raw.githubusercontent.com/curiosity-ai/orchestrator/refs/heads/main/update-service.sh | sudo sh
#
# Runs install.sh against the service's program folder, as "Upgrading" in the README does, then restarts the
# service. The program it replaces is kept as <folder>.previous. If the new one does not stay up, the old one is
# put back and the service restarted. The workspaces are containers and keep running throughout; the data
# (ORC_STORAGE) and the settings are not touched. The console's About page does the same from the browser.
#
#   --rollback    go back to <folder>.previous, the program before the last update
#   --yes         accepted for symmetry with install-service.sh; nothing here asks
#
#   ORC_VERSION=v26.10.6452       install that release instead of the latest
#   GITHUB_TOKEN=...              as for install.sh (pass it through `sudo env`)
#
# Plain POSIX sh; everything is inside main(), which runs on the last line.

set -eu

REPO="curiosity-ai/orchestrator"
RAW="https://raw.githubusercontent.com/$REPO/refs/heads/main"
SERVICE="curiosity-orchestrator"
UNIT_FILE="/etc/systemd/system/$SERVICE.service"

say()  { printf '%s\n' "$*"; }
warn() { printf 'update-service: %s\n' "$*" >&2; }
die()  { printf 'update-service: %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "this needs '$1'"; }

# The value of a key in the unit file, e.g. ExecStart.
unit_value() { sed -n "s/^$1=//p" "$UNIT_FILE" | head -n 1; }

installer_path() {
  case "$(basename "$0")" in
    update-service.sh) [ -f "$(dirname "$0")/install.sh" ] && { printf '%s' "$(dirname "$0")/install.sh"; return 0; } ;;
  esac

  target="$WORK/install.sh"
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$RAW/install.sh" -o "$target" || die "could not download $RAW/install.sh"
  else need wget; wget -qO "$target" "$RAW/install.sh" || die "could not download $RAW/install.sh"; fi

  printf '%s' "$target"
}

# Active, and still active a few seconds later: a program that dies at start is restarted and looks active in between.
wait_for_service() {
  i=0
  while [ "$i" -lt 15 ]; do
    if [ "$(systemctl is-active "$SERVICE" 2>/dev/null || true)" = active ]; then
      sleep 5
      [ "$(systemctl is-active "$SERVICE" 2>/dev/null || true)" = active ] && return 0
    fi
    i=$((i + 1))
    sleep 2
  done
  return 1
}

own() { chown -R "$SVC_USER:$SVC_GROUP" "$APP_DIR" "$APP_DIR.previous" 2>/dev/null || chown -R "$SVC_USER:$SVC_GROUP" "$APP_DIR"; }

# Puts <folder>.previous in place of the program, keeping what was there as <folder>.failed until the next update.
swap_back() {
  rm -rf "$APP_DIR.failed"
  mv "$APP_DIR" "$APP_DIR.failed"
  mv "$APP_DIR.previous" "$APP_DIR"
}

run_installer() {
  # Its closing hints (PATH, how to start it by hand) are for a desktop install: only the part up to "is installed" is shown.
  if ! env ORC_INSTALL="$INSTALL_ROOT" ORC_NO_MODIFY_PATH=1 sh "$installer" > "$WORK/installer.log" 2>&1; then
    cat "$WORK/installer.log" >&2
    die "the release could not be installed; the running program is untouched"
  fi

  sed -e '/^$/d' -e '/^The Curiosity Orchestrator .* is installed\./q' "$WORK/installer.log"
}

main() {
  ROLLBACK=0
  for arg in "$@"; do
    case "$arg" in
      --rollback)  ROLLBACK=1 ;;
      --yes | -y)  ;;
      --help | -h) sed -n '2,16p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) die "unknown option: $arg (try --help)" ;;
    esac
  done

  [ "$(uname -s)" = Linux ] || die "this updates a systemd service, which needs Linux"
  [ "$(id -u)" = 0 ] || die "run it as root: curl -fsSL $RAW/update-service.sh | sudo sh"
  need systemctl
  [ -f "$UNIT_FILE" ] || die "$UNIT_FILE does not exist: install the service first with install-service.sh"

  exe="$(unit_value ExecStart)"
  APP_DIR="$(dirname "$exe")"
  INSTALL_ROOT="$(dirname "$APP_DIR")"
  SVC_USER="$(unit_value User)"
  SVC_GROUP="$(unit_value Group)"

  [ "$(basename "$APP_DIR")" = orchestrator ] && [ -x "$exe" ] || die "the service runs $exe, which is not an install made by install.sh (…/orchestrator/curiosity-orchestrator)"
  [ -n "$SVC_USER" ] && [ -n "$SVC_GROUP" ] || die "$UNIT_FILE names no User= and Group="

  if [ "$ROLLBACK" = 1 ]; then
    [ -d "$APP_DIR.previous" ] || die "there is no $APP_DIR.previous to go back to"
    say "Rolling back to $APP_DIR.previous"
    systemctl stop "$SERVICE"
    swap_back
    chown -R "$SVC_USER:$SVC_GROUP" "$APP_DIR"
    systemctl start "$SERVICE"
    wait_for_service || die "the service did not stay up after the rollback: journalctl -u $SERVICE -e"
    say "Rolled back. The program that was replaced is in $APP_DIR.failed."
    exit 0
  fi

  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"; rm -rf "$APP_DIR.previous.new"' EXIT
  trap 'rm -rf "$WORK"; rm -rf "$APP_DIR.previous.new"; exit 130' INT TERM

  installer="$(installer_path)"

  say "Updating the Curiosity Orchestrator in $APP_DIR"

  # A copy of what runs now, so a rollback has something to go back to. It only becomes <folder>.previous once the update is in.
  rm -rf "$APP_DIR.previous.new"
  cp -a "$APP_DIR" "$APP_DIR.previous.new"

  run_installer

  if cmp -s "$exe" "$APP_DIR.previous.new/curiosity-orchestrator"; then
    chown -R "$SVC_USER:$SVC_GROUP" "$APP_DIR"
    say ""
    say "Already on the latest release; the service was not restarted."
    exit 0
  fi

  rm -rf "$APP_DIR.previous"
  mv "$APP_DIR.previous.new" "$APP_DIR.previous"
  chown -R "$SVC_USER:$SVC_GROUP" "$APP_DIR" "$APP_DIR.previous"

  say "  restarting the service"
  systemctl restart "$SERVICE"

  if ! wait_for_service; then
    warn "the new program did not stay up; putting the old one back"
    journalctl -u "$SERVICE" -n 30 --no-pager 2>/dev/null || true

    systemctl stop "$SERVICE"
    swap_back
    chown -R "$SVC_USER:$SVC_GROUP" "$APP_DIR"
    systemctl start "$SERVICE"
    wait_for_service || die "the old program did not stay up either: journalctl -u $SERVICE -e"
    die "the update failed and was rolled back; the failing program is in $APP_DIR.failed"
  fi

  say ""
  say "Updated. The workspaces were not stopped."
  say "The program it replaced is kept in $APP_DIR.previous: update-service.sh --rollback goes back to it."
}

main "$@"
