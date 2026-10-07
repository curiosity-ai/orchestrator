# Curiosity Orchestrator

Host several [Curiosity](https://curiosity.ai) workspaces on one machine, behind a single address.

The orchestrator runs each workspace as a Docker container of
[`curiosityai/curiosity`](https://hub.docker.com/r/curiosityai/curiosity), and sits in front of them:

- **A public landing page** lists the published workspaces. Opening a sleeping workspace shows a starting page
  that wakes it, then takes you in when it is ready.
- **A management console** (`/#/manage`, password protected):
  - create, delete, start, stop and restart workspaces;
  - update their image, one at a time or all outdated ones at once;
  - keep a workspace warm for up to 7 days;
  - back a workspace's data up, restore it, or reset it to empty;
  - watch CPU, memory, network and disk per workspace and for the whole host;
  - read and download container logs, the activity history and the effective settings.
- **A reverse proxy:** `https://example.com/acme/...` and `https://acme.example.com/...` both reach the workspace
  `acme`, HTTP and websockets alike.
- **Sleep and wake:** a workspace with no traffic for an hour is stopped, and opening it again starts it.
- **HTTPS:** your own certificate, a self-signed one, or certificates from Let's Encrypt, renewed automatically.
- **Scripting:** the management API also accepts a bearer token.

The releases are self-contained: no .NET installation is needed. All you need is Docker.

## Install

**Linux and macOS:**

```bash
curl -fsSL https://raw.githubusercontent.com/curiosity-ai/orchestrator/refs/heads/main/install.sh | sh
```

**Windows** (PowerShell 5.1 or 7):

```powershell
irm https://raw.githubusercontent.com/curiosity-ai/orchestrator/refs/heads/main/install.ps1 | iex
```

The script downloads the latest release for your platform and checks its SHA-256. It installs the program in
`~/.curiosity/orchestrator` and puts it on your `PATH`:

- **Linux and macOS:** a launcher goes in `~/.curiosity/bin`, and your shell profile gets that folder on `PATH`.
- **Windows:** the program folder is added to your user `PATH`.

**Settings**, all optional, as environment variables:

| Variable | Meaning |
|---|---|
| `ORC_VERSION` | Install a specific release, such as `v26.10.6452`, instead of the latest |
| `ORC_INSTALL` | Install under another folder instead of `~/.curiosity` |
| `ORC_NO_MODIFY_PATH=1` | Leave `PATH` and your shell profile alone |
| `GITHUB_TOKEN` | A GitHub token, if you hit the API's anonymous rate limit (`GH_TOKEN` works too) |

```bash
curl -fsSL https://raw.githubusercontent.com/curiosity-ai/orchestrator/main/install.sh | ORC_VERSION=v26.10.6452 sh
```

**To upgrade**, run the script again. It replaces the program folder; your data is stored elsewhere (see
`ORC_STORAGE`), so it is kept. Restart the orchestrator afterwards. On Windows, stop it first: Windows locks the
folder of a running program.

**Docker** is not installed by the script. The script warns you when it cannot find it.

### Manual download

Every [release](https://github.com/curiosity-ai/orchestrator/releases) has an archive per platform: `linux-x64`,
`linux-arm64`, `osx-x64`, `osx-arm64` and `win-x64`. Check yours against the release's `SHA256SUMS`, then extract it
and run it:

```bash
tar -xzf curiosity-orchestrator-<version>-linux-x64.tar.gz
cd curiosity-orchestrator-<version>-linux-x64
ORC_ADMIN_PASSWORD='choose-a-password' ./curiosity-orchestrator
```

Keep the folder together: it holds the server, its native database library and the web front-end (`wwwroot/`).

## Quick start

```bash
ORC_ADMIN_PASSWORD='choose-a-password' curiosity-orchestrator
```

1. Open <http://localhost:8080/#/manage> and sign in as `admin` with that password.
2. Create a workspace, say `acme`. The orchestrator pulls the Curiosity image the first time, which takes a while.
3. Open <http://localhost:8080/acme/>, or <http://acme.localhost:8080/>: browsers resolve `*.localhost` to your
   own machine.

Data goes to `./storage` unless `ORC_STORAGE` names another folder. For anything beyond a try-out, set it:

```bash
ORC_ADMIN_PASSWORD='choose-a-password' ORC_STORAGE="$HOME/.curiosity/orchestrator-data" curiosity-orchestrator
```

### On a server

See [Running on a server](#running-on-a-server) for a public server with HTTPS from Let's Encrypt.

## Running on a server

This sets up the orchestrator on a Linux server as a systemd service, with certificates from Let's Encrypt. The
examples use `workspaces.example.com`; replace it with your own domain. To run it in Docker instead, see
[Docker](#docker).

### 1. Prepare the server

- **DNS:** point two records at the server's public IP address (an `A` record, plus `AAAA` for IPv6):
  - `workspaces.example.com`, for the orchestrator itself;
  - `*.workspaces.example.com`, so that every workspace also has its own subdomain (`acme.workspaces.example.com`).
- **Firewall:** open ports **80** and **443** to the internet. Let's Encrypt connects to them to check that you
  control the names, and nothing else on the server may be using them.
- **Docker:** install [Docker Engine](https://docs.docker.com/engine/install/) and make sure it starts at boot.

### 2. Install

Create a user for the service. It needs to be in the `docker` group to manage the workspaces' containers, and its
home folder holds the orchestrator's data:

```bash
sudo useradd --system --create-home --home-dir /var/lib/curiosity-orchestrator --groups docker curiosity
```

Install the program into `/opt/curiosity`:

```bash
curl -fsSL https://raw.githubusercontent.com/curiosity-ai/orchestrator/refs/heads/main/install.sh \
  | sudo env ORC_INSTALL=/opt/curiosity ORC_NO_MODIFY_PATH=1 sh
```

### 3. Configure

Put the settings in `/etc/curiosity-orchestrator.env`, readable by root only, since it holds the console password:

```bash
sudo install -m 600 /dev/null /etc/curiosity-orchestrator.env
sudo nano /etc/curiosity-orchestrator.env
```

```ini
ORC_ADMIN_PASSWORD=choose-a-long-password
ORC_STORAGE=/var/lib/curiosity-orchestrator
ORC_PUBLIC_ADDRESS=https://workspaces.example.com

ORC_LETSENCRYPT=true
ORC_LETSENCRYPT_EMAIL=ops@example.com
ORC_LETSENCRYPT_ACCEPT_TERMS=true
# Start with Let's Encrypt's staging server; remove this line once everything works (see step 5).
ORC_LETSENCRYPT_STAGING=true
```

`ORC_LETSENCRYPT_ACCEPT_TERMS=true` accepts the Let's Encrypt
[subscriber agreement](https://letsencrypt.org/repository/). The e-mail address gets expiry warnings if renewal
ever fails. Every other setting is in [Configuration](#configuration); put it in the same file.

### 4. Start the service

Create `/etc/systemd/system/curiosity-orchestrator.service`:

```ini
[Unit]
Description=Curiosity Orchestrator
Wants=network-online.target docker.service
After=network-online.target docker.service

[Service]
User=curiosity
Group=curiosity
SupplementaryGroups=docker
EnvironmentFile=/etc/curiosity-orchestrator.env
WorkingDirectory=/var/lib/curiosity-orchestrator
ExecStart=/opt/curiosity/orchestrator/curiosity-orchestrator
# Lets the service listen on ports 80 and 443 without running as root.
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=on-failure
RestartSec=10
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now curiosity-orchestrator
journalctl -u curiosity-orchestrator -f
```

The orchestrator now listens on 443 (HTTPS) and 80 (which answers Let's Encrypt and redirects everything else to
HTTPS). Within a minute it should log the certificate for `workspaces.example.com` being issued.

### 5. Check it, then switch to real certificates

1. Open `https://workspaces.example.com/#/manage` and sign in as `admin`. With the staging server your browser warns
   that the certificate is not trusted: that is expected, staging certificates are for testing only.
2. Open **Settings**. Every host name should show as valid. A name that failed (DNS not pointing at the server yet,
   a port closed) is retried every 15 minutes; the log says why it failed.
3. Create a workspace and open it at `https://acme.workspaces.example.com/`. Its certificate is issued within
   about 10 minutes of creating it.

When all of that works, switch to real certificates. Remove the `ORC_LETSENCRYPT_STAGING=true` line from
`/etc/curiosity-orchestrator.env`, then delete the staging certificates, which would otherwise be kept until they
are due for renewal:

```bash
sudo systemctl stop curiosity-orchestrator
sudo rm -rf /var/lib/curiosity-orchestrator/letsencrypt
sudo systemctl start curiosity-orchestrator
```

### Upgrading

Run the install command again, then restart the service:

```bash
curl -fsSL https://raw.githubusercontent.com/curiosity-ai/orchestrator/refs/heads/main/install.sh \
  | sudo env ORC_INSTALL=/opt/curiosity ORC_NO_MODIFY_PATH=1 sh
sudo systemctl restart curiosity-orchestrator
```

Restarting the orchestrator does not stop the workspaces, and certificates are kept in
`/var/lib/curiosity-orchestrator/letsencrypt`, so nothing is re-issued.

### Variations

- **Your own certificate** instead of Let's Encrypt: leave out the `ORC_LETSENCRYPT*` lines and set `ORC_CERT_FILE`
  (a PFX, or a PEM with `ORC_CERT_FILE_PRIVATE_KEY`), plus `ORC_PORT_HTTP=80` to redirect `http://` to HTTPS. It
  must cover `*.workspaces.example.com` too for the workspaces' subdomains.
- **A separate host name for the console**, recommended when workspace administrators are not fully trusted (see
  [Security](#security)): add `ORC_MANAGEMENT_HOST=manage.example.com` and a DNS record for it. Let's Encrypt
  includes it in the orchestrator's certificate.
- **No subdomains:** with `ORC_SUBDOMAIN_ROUTING=false` workspaces are served only at
  `https://workspaces.example.com/{slug}/`. Then no wildcard DNS record is needed, and only one certificate is
  issued.
- **Without systemd:** the service needs permission to listen on ports below 1024. Either run it as root, or grant
  the program that permission with
  `sudo setcap cap_net_bind_service=+ep /opt/curiosity/orchestrator/curiosity-orchestrator`. An upgrade replaces
  that file, so run `setcap` again after each one.

## Docker

The orchestrator also runs as a container itself. It needs the Docker socket to manage the workspaces' containers.

This `Dockerfile` builds an image from a release:

```dockerfile
FROM mcr.microsoft.com/dotnet/runtime-deps:10.0
ARG VERSION
ARG RID=linux-x64
ADD https://github.com/curiosity-ai/orchestrator/releases/download/v${VERSION}/curiosity-orchestrator-${VERSION}-${RID}.tar.gz /tmp/orchestrator.tar.gz
RUN tar -xzf /tmp/orchestrator.tar.gz -C /opt \
 && mv /opt/curiosity-orchestrator-${VERSION}-${RID} /app \
 && rm /tmp/orchestrator.tar.gz
WORKDIR /app
ENV ORC_STORAGE=/data \
    ORC_CONTAINER_ACCESS=network
VOLUME /data
EXPOSE 8080 443
ENTRYPOINT ["./curiosity-orchestrator"]
```

Next to it, a `docker-compose.yml`:

```yaml
services:
  orchestrator:
    build:
      context: .
      args:
        VERSION: 26.10.6452          # a release from https://github.com/curiosity-ai/orchestrator/releases
        RID: linux-x64               # linux-arm64 on an Arm host
    image: curiosity-orchestrator
    restart: unless-stopped
    environment:
      - ORC_ADMIN_PASSWORD=${ORC_ADMIN_PASSWORD:?Set ORC_ADMIN_PASSWORD}
      - ORC_PUBLIC_ADDRESS=${ORC_PUBLIC_ADDRESS:-https://localhost}
      - ORC_CERT_SELF_SIGNED=true
      - ORC_PORT=443
      - ORC_PORT_LOCAL=8080
      - ORC_REDIRECT_TO_HTTPS=true
      # Let's Encrypt instead of the self-signed certificate (ports 443 and 80 reachable from the internet):
      # - ORC_LETSENCRYPT=true
      # - ORC_LETSENCRYPT_EMAIL=ops@example.com
      # - ORC_LETSENCRYPT_ACCEPT_TERMS=true
      # - ORC_PORT_HTTP=8080
    ports:
      - "443:443"
      - "80:8080"
    volumes:
      - orchestrator-data:/data
      - /var/run/docker.sock:/var/run/docker.sock
    stop_grace_period: 1m

volumes:
  orchestrator-data:
```

```bash
ORC_ADMIN_PASSWORD='choose-a-password' docker compose up -d
```

This serves HTTPS with a self-signed certificate. For certificates from Let's Encrypt, prepare DNS and the firewall
as in [Running on a server](#1-prepare-the-server), then replace the `environment` section with:

```yaml
    environment:
      - ORC_ADMIN_PASSWORD=${ORC_ADMIN_PASSWORD:?Set ORC_ADMIN_PASSWORD}
      - ORC_PUBLIC_ADDRESS=https://workspaces.example.com
      - ORC_PORT=443
      - ORC_PORT_HTTP=8080              # the port published as 80: Let's Encrypt, and the redirect to HTTPS
      - ORC_LETSENCRYPT=true
      - ORC_LETSENCRYPT_EMAIL=ops@example.com
      - ORC_LETSENCRYPT_ACCEPT_TERMS=true
      - ORC_LETSENCRYPT_STAGING=true    # remove once it works, see below
```

Check it as in [step 5](#5-check-it-then-switch-to-real-certificates). To switch from staging to real
certificates, remove the staging line and delete the staging certificates from the data volume:

```bash
docker compose stop
docker compose run --rm --entrypoint rm orchestrator -rf /data/letsencrypt
docker compose up -d
```

In a container, the orchestrator joins the workspaces' Docker network and reaches each one by container name.

## Configuration

Every setting is an environment variable. A command-line argument (`--ORC_PORT=9000`) also works, as does an
`orchestrator.json` or `orchestrator.yml` in the working directory; later sources win. The console's **Settings**
page shows the effective values and where each came from, with secrets masked.

| Variable | Default | Meaning |
|---|---|---|
| `ORC_ADMIN_PASSWORD` | — **required** | Password of the management console, at least 8 characters |
| `ORC_ADMIN_USER` | `admin` | Console user name |
| `ORC_TITLE` / `ORC_SUBTITLE` | `Curiosity` / … | Landing page heading |
| `ORC_SESSION_HOURS` | `12` | How long a console sign-in lasts |
| `ORC_API_TOKEN` | — | Enables `Authorization: Bearer <token>` on the management API, for scripts (at least 24 characters) |
| `ORC_STORAGE` | `./storage` | Where the orchestrator keeps its database and certificates |
| `ORC_PORT` | `8080`, or `443` with a certificate | Listening port |
| `ORC_PORT_LOCAL` | `8080` (HTTPS only) | Extra plain-HTTP port. Loopback only, or every address with `ORC_REDIRECT_TO_HTTPS`. `0` disables it. |
| `ORC_RESTRICT_LOCALHOST` | `false` | Listen on loopback only |
| `ORC_PUBLIC_ADDRESS` | — | Public URL. Named in the self-signed certificate, and the redirect target for `ORC_MANAGEMENT_HOST`. |
| `ORC_MANAGEMENT_HOST` | — | Serve the console and its API only on this host name (see [Security](#security)) |
| `ORC_SUBDOMAIN_ROUTING` | `true` | Also serve each workspace at `{slug}.{host}/` (see [Subdomains](#subdomains)) |
| `ORC_WWW_FOLDER` | `./wwwroot` | Front-end files |
| `ORC_MAX_BODY_SIZE` | 512 MB | Largest request body (uploads into a workspace) |
| `ORC_LOG_LEVEL` | `Information` | |
| **HTTPS** | | |
| `ORC_CERT_FILE` | — | A PFX, a CER, or a PEM certificate |
| `ORC_CERT_FILE_PRIVATE_KEY` | — | PEM private key, when `ORC_CERT_FILE` is a PEM |
| `ORC_CERT_PWD` | — | Password of the PFX, or of an encrypted PEM key |
| `ORC_CERT_SELF_SIGNED` | `false` | Generate a self-signed certificate (5 years) into `ORC_STORAGE/self.pfx` and reuse it |
| `ORC_REDIRECT_TO_HTTPS` / `ORC_USE_HSTS` | `false` | |
| `ORC_PORT_HTTP` | `80` with Let's Encrypt, else `0` | Public plain-HTTP port next to HTTPS: answers ACME HTTP-01 challenges and redirects everything else to HTTPS |
| **Let's Encrypt** | | See [HTTPS with Let's Encrypt](#https-with-lets-encrypt) |
| `ORC_LETSENCRYPT` | `false` | Get certificates from Let's Encrypt and renew them |
| `ORC_LETSENCRYPT_EMAIL` | — | Required with it: the account address, which gets expiry warnings |
| `ORC_LETSENCRYPT_ACCEPT_TERMS` | `false` | Required `true` with it: accepts the [subscriber agreement](https://letsencrypt.org/repository/) |
| `ORC_LETSENCRYPT_DOMAINS` | hosts of `ORC_PUBLIC_ADDRESS` and `ORC_MANAGEMENT_HOST` | The orchestrator's own host names, comma-separated, on one certificate |
| `ORC_LETSENCRYPT_WORKSPACES` | `true` (with `ORC_SUBDOMAIN_ROUTING`) | A certificate per workspace for `{slug}.{host of ORC_PUBLIC_ADDRESS}` |
| `ORC_LETSENCRYPT_STAGING` | `false` | Let's Encrypt's staging server: untrusted certificates, much higher rate limits |
| `ORC_LETSENCRYPT_SERVER` | — | Another ACME directory URL (a private CA) |
| `ORC_LETSENCRYPT_ISSUERS` | — | PEM files of that CA's root and intermediates, comma-separated |
| **Docker** | | |
| `ORC_DOCKER_ENDPOINT` | `unix:///var/run/docker.sock` (Windows: `npipe://./pipe/docker_engine`) | Also `tcp://host:2375` |
| `ORC_DOCKER_NETWORK` | `curiosity-orchestrator` | Bridge network the workspaces join (created if missing) |
| `ORC_CONTAINER_ACCESS` | `auto` | `port`: publish each workspace on `127.0.0.1:<random>`. `network`: reach it by container name. `auto` picks `network` inside a container, `port` otherwise. |
| `ORC_CONTAINER_PREFIX` | `curiosity-` | Prefix of container and volume names |
| `ORC_DEFAULT_IMAGE` | `curiosityai/curiosity:latest` | Image for new workspaces |
| `ORC_DEFAULT_MEMORY_LIMIT` / `ORC_DEFAULT_CPU_LIMIT` | `0` (none) | Defaults for new workspaces, in MB and cores |
| `ORC_INSTANCE_PORT` | `8080` | Port Curiosity listens on inside the container |
| `ORC_INSTANCE_NOFILE` | `0` (Docker's default) | Open-file limit for workspaces (Curiosity's own deployments use `500000`) |
| `ORC_INSTANCE_ENV_<NAME>` | — | Passed to **every** workspace as `<NAME>`, e.g. `ORC_INSTANCE_ENV_MSK_LICENSE` |
| **Lifecycle** | | |
| `ORC_IDLE_TIMEOUT_MINUTES` | `60` | Stop a workspace after this long without traffic |
| `ORC_MAX_KEEP_WARM_DAYS` | `7` | Longest "keep warm", 0 to 7 days |
| `ORC_MAX_RUNNING_INSTANCES` | `0` (no limit) | Most workspaces running at once (see [Capacity](#sleep-and-wake)) |
| `ORC_START_TIMEOUT_MINUTES` | `15` | Give up on a start that does not become ready |
| `ORC_STOP_TIMEOUT_SECONDS` | `600` | Grace period for a stop: Curiosity saves its graph on the way down |
| `ORC_STATS_INTERVAL_SECONDS` | `15` | Resource sampling interval |

## How it works

### Workspaces

Each workspace is one container, `{prefix}{slug}`, and one Docker volume, `{prefix}{slug}-data`, mounted at
`/DATA`.

- **Data lives in the volume.** Updating the image, changing limits or environment variables re-creates the
  container but never touches the volume. Deleting a workspace removes its volume only when you ask.
- **The orchestrator owns updates.** It turns off Curiosity's own Docker update check; update from the console.
- **Stopping is graceful.** Curiosity saves its graph when it stops, so a stop waits up to 10 minutes.

### Sleep and wake

- **Waking up.** Opening a stopped workspace in the browser shows a starting page that starts it and takes you in
  once Curiosity is ready. Background requests (API calls, a stale tab polling) get `503` and do *not* wake it.
- **Going to sleep.** Every request counts as activity, and a request in progress (an upload, a download) keeps the
  workspace up. A workspace idle for `ORC_IDLE_TIMEOUT_MINUTES` is stopped. A tab left open does not keep it
  awake.
- **Keep warm.** Keeps a workspace running until a date, at most `ORC_MAX_KEEP_WARM_DAYS` away. It is a
  guarantee: a kept-warm workspace found stopped (a crash, a reboot) is started again. Stopping it from the console
  clears it.
- **Capacity.** With `ORC_MAX_RUNNING_INSTANCES` set, waking a workspace on a full server stops the least recently
  used one that nobody is using: not kept warm, nothing in progress, and idle for at least 5 minutes. When every
  running workspace is in use, the start is refused and the starting page says so.

### Backups

The **Data** tab of a workspace offers:

- **Download backup:** the workspace's data as a `.tar.gz`. The workspace is stopped first, so the backup is
  consistent.
- **Restore:** replaces the data with such a backup, from this workspace or another. The upload is checked in full
  before anything is deleted.
- **Reset:** starts over with empty data at the same address.

They are scriptable with `ORC_API_TOKEN`:

```bash
curl -H "Authorization: Bearer $ORC_API_TOKEN" -o acme.tar.gz https://example.com/api/admin/instances/acme/backup
curl -H "Authorization: Bearer $ORC_API_TOKEN" -H 'Content-Type: application/octet-stream' \
     --data-binary @acme.tar.gz https://example.com/api/admin/instances/acme-copy/restore
```

### The proxy

`/{slug}/x` is forwarded to the workspace's `/x`, with `X-Forwarded-*` headers. Cookies and redirects are
re-scoped to `/{slug}/`, so workspaces on one host do not overwrite each other's sign-in.

Workspace names `admin`, `default`, `www`, `commit-*` and `preview-*` are reserved.

#### Subdomains

With `ORC_SUBDOMAIN_ROUTING` on (the default), a workspace is also served at the root of its own subdomain: the
first label of the host names the workspace.

| Request | Goes to |
|---|---|
| `https://example.com/aviation/search` | `aviation`'s `/search` |
| `https://aviation.example.com/search` | `aviation`'s `/search` |
| `https://example.com/`, `https://www.example.com/` | the orchestrator |
| `https://nothing-by-this-name.example.com/` | the orchestrator (no such workspace) |

- **Waking up** on a subdomain goes through the orchestrator's starting page and returns to the original URL.
- **Never matched:** an IP address, a single-label host (`localhost`), and the hosts of `ORC_PUBLIC_ADDRESS` and
  `ORC_MANAGEMENT_HOST`. If the orchestrator itself lives on a subdomain, set `ORC_PUBLIC_ADDRESS`, so that a
  workspace with the same name cannot take it over.
- **What it needs:** a wildcard DNS record (`*.example.com`) and a certificate that covers it. Let's Encrypt
  issues one per workspace; the self-signed certificate includes `*.{host of ORC_PUBLIC_ADDRESS}`.

### HTTPS with Let's Encrypt

[Running on a server](#running-on-a-server) walks through the setup. How it works:

| Host name | Certificate |
|---|---|
| `workspaces.example.com` (`ORC_LETSENCRYPT_DOMAINS`) | one certificate for all of them, issued at start-up |
| `aviation.workspaces.example.com` | the workspace's own, issued at start-up, or within about 10 minutes for a new workspace |
| anything else (an IP address, a name still waiting) | `ORC_CERT_FILE` when set, otherwise a self-signed certificate |

- **Requirements:** ports 443 and 80 reachable from the internet, and DNS for every name pointing at the server.
  Names are validated over TLS on 443, or over HTTP on `ORC_PORT_HTTP`.
- **No wildcard certificate:** that would need a DNS challenge, so each workspace gets a certificate of its own.
- **Renewal** happens 30 days before expiry. Certificates and the account key are kept in
  `ORC_STORAGE/letsencrypt`; back that folder up with the rest of `ORC_STORAGE`.
- **Failures** (DNS not set up yet, a port closed) are retried every 15 minutes, which stays within Let's
  Encrypt's limits.
- **Status:** the console's **Settings** page lists every name with its state and expiry.
- **Rate limits:** Let's Encrypt issues 50 certificates per registered domain per week, and each workspace is one.
  Use `ORC_LETSENCRYPT_STAGING=true` while trying things out, and delete `ORC_STORAGE/letsencrypt` when you
  switch to the real server.

### The workspace administrator

The orchestrator creates each workspace's `admin` account with a random password and keeps it. It uses it to name
the workspace and to open it for you already signed in. The workspace's **Administrator** tab reveals the
password and rotates it.

## Security

- **Console sign-in** is a single user. Its session cookie is HttpOnly and `SameSite=Strict`, and failed sign-ins
  are throttled.
- **`ORC_API_TOKEN`** grants the same access as the console. Keep it secret.
- **Untrusted workspace administrators.** Workspaces on paths share the orchestrator's origin, so a workspace
  administrator who adds custom front-end code could act as a signed-in console user. If you do not trust them,
  set `ORC_MANAGEMENT_HOST` to a separate host name (e.g. `manage.example.com`): the console then answers only
  there. Opening workspaces on their subdomains gives each one its own origin too.
- **`ORC_STORAGE`** holds the workspaces' administrator passwords. Protect it like a secret.
- **The Docker socket** is root-equivalent on the host.
