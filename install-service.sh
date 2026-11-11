#!/bin/sh
# Install the Curiosity Orchestrator as a systemd service on a Linux server, with HTTPS from Let's Encrypt.
#
#   curl -fsSL https://raw.githubusercontent.com/curiosity-ai/orchestrator/refs/heads/main/install-service.sh | sudo sh
#
# It does what "Running on a server" in the README describes: creates the `curiosity` user (in the docker group),
# installs the release into /opt/curiosity, writes the settings to /etc/curiosity-orchestrator.env (root only, it
# holds the console password), writes the systemd unit and starts it. It asks for what it needs. Run it again to
# reinstall the program and the unit; the settings are kept unless you pass --reconfigure.
#
# Every question can be answered up front, as an environment variable (the same names as the settings), and then
# nothing is asked. Through sudo, pass them with `sudo env`:
#
#   curl -fsSL .../install-service.sh | sudo env ORC_ADMIN_PASSWORD=... ORC_PUBLIC_ADDRESS=https://workspaces.example.com \
#       ORC_LETSENCRYPT_EMAIL=ops@example.com ORC_LETSENCRYPT_ACCEPT_TERMS=true sh -s -- --yes
#
#   ORC_ADMIN_PASSWORD             the console password, at least 8 characters (asked; empty generates one)
#   ORC_PUBLIC_ADDRESS             https://workspaces.example.com (asked)
#   ORC_STORAGE                    where the data goes (default /var/lib/curiosity-orchestrator)
#   ORC_LETSENCRYPT                true or false (asked, default true)
#   ORC_LETSENCRYPT_EMAIL          the Let's Encrypt account address, which gets expiry warnings (asked)
#   ORC_LETSENCRYPT_ACCEPT_TERMS   true accepts the Let's Encrypt subscriber agreement (asked)
#   ORC_LETSENCRYPT_STAGING        true tries Let's Encrypt's staging server first (asked, default true)
#   ORC_SUBDOMAIN_ROUTING          false serves workspaces at /{slug}/ only, with no wildcard DNS record (asked)
#   ORC_MANAGEMENT_HOST            a separate host name for the console (optional)
#   ORC_SERVICE_USER               the service's user (default curiosity)
#   ORC_INSTALL                    where the program goes (default /opt/curiosity)
#   ORC_VERSION, GITHUB_TOKEN      as for install.sh
#
# Options: --reconfigure (ask again and rewrite the settings), --yes (never ask; a missing answer is an error), --help.
#
# Plain POSIX sh. Everything is inside main(), which runs on the last line: a download cut off halfway runs nothing.

set -eu

REPO="curiosity-ai/orchestrator"
RAW="https://raw.githubusercontent.com/$REPO/refs/heads/main"
SERVICE="curiosity-orchestrator"
ENV_FILE="/etc/$SERVICE.env"
UNIT_FILE="/etc/systemd/system/$SERVICE.service"
DEFAULT_DATA="/var/lib/$SERVICE"

SVC_USER="${ORC_SERVICE_USER:-curiosity}"
INSTALL_ROOT="${ORC_INSTALL:-/opt/curiosity}"

say()  { printf '%s\n' "$*"; }
warn() { printf 'install-service: %s\n' "$*" >&2; }
die()  { printf 'install-service: %s\n' "$*" >&2; exit 1; }

RECONFIGURE=0
ASSUME_YES="${ORC_ASSUME_YES:-0}"
GENERATED=0

# Questions are asked on the terminal, which is still there when the script itself comes through a pipe.
have_tty() { [ -r /dev/tty ] && [ -w /dev/tty ] && ( : < /dev/tty ) 2>/dev/null; }
can_ask()  { [ "$ASSUME_YES" != 1 ] && have_tty; }

# ask VAR "question" [default]: leaves VAR alone when it is already set.
ask() {
  var="$1"; question="$2"; default="${3:-}"
  eval "current=\${$var:-}"
  [ -z "$current" ] || return 0

  if can_ask; then
    if [ -n "$default" ]; then printf '%s [%s]: ' "$question" "$default" > /dev/tty; else printf '%s: ' "$question" > /dev/tty; fi
    IFS= read -r answer < /dev/tty || answer=""
    [ -n "$answer" ] || answer="$default"
  else
    answer="$default"
  fi

  eval "$var=\$answer"
}

# ask_yes VAR "question" default(true|false): VAR becomes "true" or "false".
ask_yes() {
  var="$1"; question="$2"; default="$3"
  eval "current=\${$var:-}"

  if [ -z "$current" ]; then
    hint="Y/n"; [ "$default" = true ] || hint="y/N"

    if can_ask; then
      printf '%s [%s]: ' "$question" "$hint" > /dev/tty
      IFS= read -r answer < /dev/tty || answer=""
    else
      answer=""
    fi

    case "$answer" in
      [Yy]*) current=true ;;
      [Nn]*) current=false ;;
      *)     current="$default" ;;
    esac
  fi

  case "$current" in
    true | TRUE | True | 1 | yes)  eval "$var=true" ;;
    false | FALSE | False | 0 | no) eval "$var=false" ;;
    *) die "$var must be true or false, not '$current'" ;;
  esac
}

ask_secret() {
  var="$1"; question="$2"
  eval "current=\${$var:-}"
  [ -z "$current" ] || return 0

  if can_ask; then
    printf '%s (empty: generate one): ' "$question" > /dev/tty
    stty -echo < /dev/tty 2>/dev/null || true
    IFS= read -r answer < /dev/tty || answer=""
    stty echo < /dev/tty 2>/dev/null || true
    printf '\n' > /dev/tty
  else
    answer=""
  fi

  if [ -z "$answer" ]; then
    answer="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 24 2>/dev/null)"
    GENERATED=1
  fi

  eval "$var=\$answer"
}

need() { command -v "$1" >/dev/null 2>&1 || die "this needs '$1'"; }

# "workspaces.example.com", "https://workspaces.example.com/" and "http://…:8080" all become an address; the host is read back out.
normalize_address() {
  a="$1"
  a="${a%/}"
  case "$a" in http://* | https://*) ;; *) a="https://$a" ;; esac
  printf '%s' "$a"
}

host_of() {
  h="${1#*://}"
  h="${h%%/*}"
  printf '%s' "${h%%:*}"
}

# KEY="value" as systemd's EnvironmentFile reads it: quoted, so a password may hold spaces and #.
env_line() {
  case "$2" in
    *'
'*) die "$1 cannot hold a line break" ;;
  esac
  escaped="$(printf '%s' "$2" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  printf '%s="%s"\n' "$1" "$escaped"
}

# The setting's value out of an existing env file, undoing env_line's quoting.
env_value() {
  sed -n "s/^$1=//p" "$ENV_FILE" | head -n 1 | sed -e 's/^"//' -e 's/"$//' -e 's/\\"/"/g' -e 's/\\\\/\\/g'
}

installer_path() {
  case "$(basename "$0")" in
    install-service.sh) [ -f "$(dirname "$0")/install.sh" ] && { printf '%s' "$(dirname "$0")/install.sh"; return 0; } ;;
  esac

  target="$WORK/install.sh"
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$RAW/install.sh" -o "$target" || die "could not download $RAW/install.sh"
  else need wget; wget -qO "$target" "$RAW/install.sh" || die "could not download $RAW/install.sh"; fi

  printf '%s' "$target"
}

gather() {
  ask ORC_PUBLIC_ADDRESS "Public address of the orchestrator (the domain whose DNS points at this server, such as workspaces.example.com)"
  [ -n "${ORC_PUBLIC_ADDRESS:-}" ] || die "a public address is needed (ORC_PUBLIC_ADDRESS)"
  ORC_PUBLIC_ADDRESS="$(normalize_address "$ORC_PUBLIC_ADDRESS")"
  HOST="$(host_of "$ORC_PUBLIC_ADDRESS")"

  ask_yes ORC_LETSENCRYPT "Get HTTPS certificates from Let's Encrypt?" true

  if [ "$ORC_LETSENCRYPT" = true ]; then
    ask ORC_LETSENCRYPT_EMAIL "E-mail address for the Let's Encrypt account (it gets expiry warnings)"
    case "${ORC_LETSENCRYPT_EMAIL:-}" in *?@?*) ;; *) die "a valid e-mail address is needed for Let's Encrypt (ORC_LETSENCRYPT_EMAIL)" ;; esac

    if [ "${ORC_LETSENCRYPT_ACCEPT_TERMS:-}" != true ]; then
      ask_yes ORC_LETSENCRYPT_ACCEPT_TERMS "Do you accept the Let's Encrypt subscriber agreement (https://letsencrypt.org/repository/)?" false
      [ "$ORC_LETSENCRYPT_ACCEPT_TERMS" = true ] || die "Let's Encrypt needs its subscriber agreement accepted (ORC_LETSENCRYPT_ACCEPT_TERMS=true)"
    fi

    ask_yes ORC_LETSENCRYPT_STAGING "Try Let's Encrypt's staging server first? (recommended: untrusted certificates, but no rate limits to trip on a DNS or firewall mistake)" true
  fi

  SUBDOMAINS="${ORC_SUBDOMAIN_ROUTING:-}"
  ask_yes SUBDOMAINS "Also serve every workspace on its own subdomain? (needs a DNS record for *.$HOST)" true
  ORC_SUBDOMAIN_ROUTING="$SUBDOMAINS"

  ask ORC_MANAGEMENT_HOST "Separate host name for the management console (optional, recommended when workspace administrators are not fully trusted)" ""

  ask ORC_STORAGE "Folder for the orchestrator's data" "$DEFAULT_DATA"
  [ -n "${ORC_STORAGE:-}" ] || ORC_STORAGE="$DEFAULT_DATA"

  ask_secret ORC_ADMIN_PASSWORD "Password for the management console (at least 8 characters)"
  [ "${#ORC_ADMIN_PASSWORD}" -ge 8 ] || die "the console password must be at least 8 characters (ORC_ADMIN_PASSWORD)"
}

write_env() {
  tmp="$ENV_FILE.new"
  ( umask 077
    {
      env_line ORC_ADMIN_PASSWORD "$ORC_ADMIN_PASSWORD"
      env_line ORC_STORAGE        "$ORC_STORAGE"
      env_line ORC_PUBLIC_ADDRESS "$ORC_PUBLIC_ADDRESS"
      [ -z "${ORC_MANAGEMENT_HOST:-}" ] || env_line ORC_MANAGEMENT_HOST "$ORC_MANAGEMENT_HOST"
      [ "$ORC_SUBDOMAIN_ROUTING" = true ] || env_line ORC_SUBDOMAIN_ROUTING false

      if [ "$ORC_LETSENCRYPT" = true ]; then
        printf '\n'
        env_line ORC_LETSENCRYPT              true
        env_line ORC_LETSENCRYPT_EMAIL        "$ORC_LETSENCRYPT_EMAIL"
        env_line ORC_LETSENCRYPT_ACCEPT_TERMS true
        if [ "$ORC_LETSENCRYPT_STAGING" = true ]; then
          printf '# Let'"'"'s Encrypt'"'"'s staging server; remove this line once everything works (README, "Check it, then switch to real certificates").\n'
          env_line ORC_LETSENCRYPT_STAGING true
        fi
      fi
    } > "$tmp" )

  chown root:root "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$ENV_FILE"
}

create_user() {
  getent group docker >/dev/null 2>&1 || die "there is no 'docker' group: install Docker Engine first (https://docs.docker.com/engine/install/), then run this again"

  if id "$SVC_USER" >/dev/null 2>&1; then
    say "  user $SVC_USER exists"
  else
    useradd --system --user-group --create-home --home-dir "$DEFAULT_DATA" --groups docker "$SVC_USER" || die "could not create the user $SVC_USER"
    say "  created user $SVC_USER (in the docker group)"
  fi

  SVC_GROUP="$(id -gn "$SVC_USER")"

  mkdir -p "$STORAGE"
  chown "$SVC_USER:$SVC_GROUP" "$STORAGE"
  chmod 770 "$STORAGE"
  say "  data folder $STORAGE"
}

write_unit() {
  cat > "$UNIT_FILE" <<UNIT
[Unit]
Description=Curiosity Orchestrator
Wants=network-online.target docker.service
After=network-online.target docker.service

[Service]
User=$SVC_USER
Group=$SVC_GROUP
SupplementaryGroups=docker
# New data files stay readable and writable by the service's group, like the folder itself.
UMask=0007
EnvironmentFile=$ENV_FILE
WorkingDirectory=$STORAGE
ExecStart=$INSTALL_ROOT/orchestrator/curiosity-orchestrator
# Lets the service listen on ports 80 and 443 without running as root.
AmbientCapabilities=CAP_NET_BIND_SERVICE
# The console's About page updates the program and then exits with 75: Restart=always is what starts the new one.
Restart=always
SuccessExitStatus=75
RestartSec=5
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
UNIT
  chmod 644 "$UNIT_FILE"
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

preflight() {
  [ "$(uname -s)" = Linux ] || die "this installs a systemd service, which needs Linux"
  [ "$(id -u)" = 0 ] || die "run it as root: curl -fsSL $RAW/install-service.sh | sudo sh"
  [ -d /run/systemd/system ] || die "systemd is not running here. Without systemd, see \"Variations\" in the README."
  need systemctl
  need useradd
  command -v curl >/dev/null 2>&1 || need wget
  command -v docker >/dev/null 2>&1 || warn "Docker was not found in PATH: the orchestrator runs every workspace as a container, so install Docker Engine."
}

check_network() {
  [ "$ORC_LETSENCRYPT" = true ] || return 0

  getent hosts "$HOST" >/dev/null 2>&1 || warn "$HOST does not resolve yet: Let's Encrypt cannot issue its certificate until its DNS record points at this server."

  if [ "$SUBDOMAINS" = true ] && ! getent hosts "orchestrator-dns-check.$HOST" >/dev/null 2>&1; then
    warn "*.$HOST does not resolve yet: workspaces get no subdomain certificate until a wildcard DNS record points at this server."
  fi

  if [ "$(systemctl is-active "$SERVICE" 2>/dev/null || true)" != active ] && command -v ss >/dev/null 2>&1; then
    if ss -ltnH 2>/dev/null | awk '{ print $4 }' | grep -Eq '[:.](80|443)$'; then
      warn "something already listens on port 80 or 443; Let's Encrypt needs both, and so does the orchestrator."
    fi
  fi
}

run_installer() {
  # Its closing hints (PATH, how to start it by hand) are for a desktop install: only the part up to "is installed" is shown.
  if ! env ORC_INSTALL="$INSTALL_ROOT" ORC_NO_MODIFY_PATH=1 sh "$installer" > "$WORK/installer.log" 2>&1; then
    cat "$WORK/installer.log" >&2
    die "the release could not be installed"
  fi

  sed -e '/^$/d' -e '/^The Curiosity Orchestrator .* is installed\./q' "$WORK/installer.log"
}

main() {
  for arg in "$@"; do
    case "$arg" in
      --reconfigure) RECONFIGURE=1 ;;
      --yes | -y)    ASSUME_YES=1 ;;
      --help | -h)   sed -n '2,32p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' ; exit 0 ;;
      *) die "unknown option: $arg (try --help)" ;;
    esac
  done

  preflight

  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  trap 'rm -rf "$WORK"; exit 130' INT TERM

  say "Installing the Curiosity Orchestrator as the systemd service '$SERVICE'"

  if [ -f "$ENV_FILE" ] && [ "$RECONFIGURE" != 1 ]; then
    say "  keeping the settings in $ENV_FILE (--reconfigure asks again)"
    STORAGE="$(env_value ORC_STORAGE)"; [ -n "$STORAGE" ] || STORAGE="$DEFAULT_DATA"
    ORC_LETSENCRYPT=false
    ADDRESS_NOTE=""
  else
    gather
    STORAGE="$ORC_STORAGE"
    check_network
    write_env
    say "  wrote $ENV_FILE (readable by root only)"
    ADDRESS_NOTE="$ORC_PUBLIC_ADDRESS"
  fi

  create_user

  installer="$(installer_path)"
  say "  installing the program into $INSTALL_ROOT/orchestrator"
  run_installer

  # The service owns its program folder: the console's About page replaces it whole when it updates itself.
  chown -R "$SVC_USER:$SVC_GROUP" "$INSTALL_ROOT"

  write_unit
  say "  wrote $UNIT_FILE"

  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null 2>&1
  systemctl restart "$SERVICE"

  say "  starting; waiting for it to stay up"

  if ! wait_for_service; then
    journalctl -u "$SERVICE" -n 30 --no-pager 2>/dev/null || true
    die "the service did not stay up: see the log above, or: journalctl -u $SERVICE -e"
  fi

  say ""
  say "The Curiosity Orchestrator is running."

  if [ -n "$ADDRESS_NOTE" ]; then
    say ""
    say "  Console   $ADDRESS_NOTE/#/manage   (user admin)"
    [ "$GENERATED" = 1 ] && say "  Password  $ORC_ADMIN_PASSWORD   (generated: it is also in $ENV_FILE)"

    say ""
    say "Before it can serve $HOST:"
    if [ "$SUBDOMAINS" = true ]; then
      say "  - DNS: an A record (plus AAAA for IPv6) for $HOST, and for *.$HOST (the workspaces' subdomains)"
    else
      say "  - DNS: an A record (plus AAAA for IPv6) for $HOST"
    fi
    [ -z "${ORC_MANAGEMENT_HOST:-}" ] || say "  - DNS: the same for the console's own host name, $ORC_MANAGEMENT_HOST"
    say "  - Firewall: ports 80 and 443 open to the internet (Let's Encrypt connects to them)"

    if [ "$ORC_LETSENCRYPT" = true ] && [ "${ORC_LETSENCRYPT_STAGING:-}" = true ]; then
      say ""
      say "It uses Let's Encrypt's staging server, so browsers warn about the certificate. When Settings shows every"
      say "name as valid, remove ORC_LETSENCRYPT_STAGING from $ENV_FILE, then:"
      say "  sudo systemctl stop $SERVICE && sudo rm -rf $STORAGE/letsencrypt && sudo systemctl start $SERVICE"
    fi

    if [ "$ORC_LETSENCRYPT" != true ]; then
      say ""
      say "No certificate is set up: it listens on port 8080 without HTTPS. Add ORC_CERT_FILE (and ORC_PORT_HTTP=80), or"
      say "ORC_LETSENCRYPT=true with its e-mail and terms, to $ENV_FILE and restart the service (README, \"Variations\")."
    fi
  fi

  say ""
  say "Logs:     journalctl -u $SERVICE -f"
  say "Settings: $ENV_FILE (then: sudo systemctl restart $SERVICE)"
  say "Updates:  the console's About page, or update-service.sh"
}

main "$@"
