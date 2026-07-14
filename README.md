# Matrix Node Installer

[![Matrix](https://img.shields.io/badge/Matrix-Synapse-0DBD8B?logo=matrix&logoColor=white)](https://matrix.org/)
[![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)](https://docs.docker.com/compose/)
[![Debian](https://img.shields.io/badge/Debian-13.6-A81D33?logo=debian&logoColor=white)](https://www.debian.org/)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04%20%7C%2026.04-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![LiveKit](https://img.shields.io/badge/LiveKit-MatrixRTC-111111)](https://livekit.io/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**English** · [Русский](README_RU.md)

An automated installer for a self-hosted Matrix infrastructure with messaging, voice calls, and video calls.

The project deploys a complete Docker Compose stack on a single Linux server:

- Matrix Synapse
- PostgreSQL
- Caddy
- Coturn
- LiveKit
- MatrixRTC JWT Service (`lk-jwt-service`).

It is intended for personal, family, and private deployments. Public registration is disabled by default; accounts are created by an administrator through the `user` and `admin` commands.

## Tested systems

| Operating system | Clean image | Fully updated | Voice/Video | Status |
|---|:---:|:---:|:---:|:---:|
| Debian 13.6 | ✅ | ✅ | ✅ | Passed |
| Ubuntu 24.04 LTS | ✅ | ✅ | ✅ | Passed |
| Ubuntu 26.04 LTS | ✅ | ✅ | ✅ | Passed |

The complete installation flow has been validated on live VPS deployments. Testing covered installation, TLS, health checks, Matrix federation, account creation, messaging, push notifications, voice and video calls, backup, and restore.

Other recent Debian and Ubuntu releases are expected to work but have not been validated.

## Features

- automated installation of the complete Matrix stack
- automatic HTTPS certificates through Caddy and Let's Encrypt
- Matrix federation over `443/tcp`, without exposing port `8448`
- TURN/STUN through Coturn
- MatrixRTC voice and video calls through LiveKit
- PostgreSQL instead of embedded SQLite
- automatic Docker and Docker Compose installation
- UFW configuration that preserves the detected SSH port
- optional swap configuration for low-memory VPS instances
- built-in health checks for every component
- regular user and administrator account creation
- backup and restore
- guarded reconfiguration with an automatic pre-update backup.

## Commands

```text
install [--force] [--yes]
check
user USERNAME
admin USERNAME
backup
restore [ARCHIVE]
```

Examples:

```bash
sudo bash ./matrix-node.sh install
sudo bash ./matrix-node.sh check
sudo bash ./matrix-node.sh user USERNAME
sudo bash ./matrix-node.sh admin USERNAME
sudo bash ./matrix-node.sh backup
sudo bash ./matrix-node.sh restore [ARCHIVE]
```

## Requirements

Supported and validated operating systems:

- Debian 13.5
- Ubuntu 24.04 LTS
- Ubuntu 26.04 LTS.

Recommended server configuration:

```text
CPU: 2 vCPU
RAM: 2 GB+
Disk: 20 GB+
Public IPv4: required
Domain name: required
```

The domain's DNS A record must point to the public IPv4 address of the server. Check it before installation:

```bash
dig +short matrix.example.org
```

The returned address must match the VPS address. The installer performs the same check before requesting a TLS certificate.

Required ports:

| Port | Protocol | Purpose |
|---|---|---|
| `80` | TCP | HTTP and ACME challenge |
| `443` | TCP | HTTPS, Matrix Client API, and Federation API |
| `3478` | TCP/UDP | Coturn TURN/STUN |
| `5349` | TCP | Coturn over TLS |
| `49160-49200` | UDP | TURN relay |
| `7881` | TCP | LiveKit RTC over TCP |
| `50000-50100` | UDP | LiveKit RTC |

## Installation

Copy `matrix-node.sh` to the server, then run:

```bash
chmod +x matrix-node.sh
sudo bash ./matrix-node.sh install
```

The installer asks for the Matrix domain and, when needed, the public IPv4 address. PostgreSQL, Coturn, and LiveKit passwords and keys are generated automatically and stored in protected configuration files.

A successful installation ends with output similar to:

```text
Healthcheck passed.
Installation completed: https://matrix.example.org
```

### Automatic UFW confirmation

To apply the firewall rules without an interactive confirmation prompt:

```bash
sudo bash ./matrix-node.sh install --yes
```

The `--yes` option applies only to the UFW confirmation in `install` mode. Other safety checks remain enabled.

### Reconfiguring an existing installation

The installer stops when it detects an existing stack to prevent accidental changes. To apply the current configuration to an existing deployment, use:

```bash
sudo bash ./matrix-node.sh install --force
```

Before changing a running deployment, the installer automatically creates a backup.

## Health check

```bash
sudo bash ./matrix-node.sh check
```

The check covers:

```text
Matrix/Synapse
PostgreSQL
Caddy/TLS
Federation
Coturn
LiveKit
lk-jwt-service
UFW
```

Successful result:

```text
Healthcheck passed.
```

## User management

Create an administrator:

```bash
sudo bash ./matrix-node.sh admin alice
```

Create a regular user:

```bash
sudo bash ./matrix-node.sh user bob
```

The password is not passed as an argument to the installer. It is requested interactively:

```text
Password:
Confirm password:
```

Example result:

```text
Admin created: @alice:matrix.example.org
User created: @bob:matrix.example.org
```

### Connecting a Matrix client

```text
Homeserver: https://matrix.example.org
Username: alice
Password: the account password
Matrix ID: @alice:matrix.example.org
```

Compatible with standard Matrix clients.

## Architecture

```text
Internet
   |
   v
Caddy :443
   |
   +--> Synapse :8008
   |
   +--> LiveKit :7880
   |
   +--> lk-jwt-service :8080

Coturn:
3478/tcp+udp
5349/tcp
49160-49200/udp

LiveKit RTC:
7881/tcp
50000-50100/udp
```

Default containers:

| Container | Default image |
|---|---|
| `postgres` | `postgres:16-alpine` |
| `synapse` | `ghcr.io/element-hq/synapse:latest` |
| `caddy` | `caddy:2` |
| `coturn` | `coturn/coturn:4.6.3` |
| `livekit` | `livekit/livekit-server:latest` |
| `lk-jwt-service` | `ghcr.io/element-hq/lk-jwt-service:latest` |

Image versions can be pinned with the `SYNAPSE_VERSION`, `POSTGRES_VERSION`, `COTURN_VERSION`, `LIVEKIT_VERSION`, `LK_JWT_VERSION`, and `CADDY_VERSION` environment variables.

## Caddy routing

```text
/.well-known/matrix/server  -> federation address at DOMAIN:443
/.well-known/matrix/client  -> homeserver and MatrixRTC LiveKit focus
/livekit/jwt/*              -> lk-jwt-service:8080
/livekit/sfu/*              -> LiveKit:7880
all other requests          -> Synapse:8008
```

PostgreSQL and the Synapse backend port are not exposed directly to the internet.

## Matrix federation

Caddy publishes `/.well-known/matrix/server` with this response:

```json
{
  "m.server": "matrix.example.org:443"
}
```

Connection flow:

```text
remote homeserver
    -> https://matrix.example.org/.well-known/matrix/server
    -> matrix.example.org:443
    -> Caddy
    -> Synapse:8008
```

Port `8448/tcp` does not need to be exposed.

Federation can be checked with the [Matrix Federation Tester](https://federationtester.matrix.org/). Enter the domain only, without `https://` or a port number.

### Manual Matrix API checks

```bash
curl -fsS "https://matrix.example.org/.well-known/matrix/server"
curl -fsS "https://matrix.example.org/.well-known/matrix/client"
curl -i "https://matrix.example.org/_matrix/federation/v1/version"
curl -i "https://matrix.example.org/_matrix/key/v2/server"
curl -i "https://matrix.example.org/_matrix/client/versions"
```

## Backup

Create a backup:

```bash
sudo bash ./matrix-node.sh backup
```

The archive is created in `.backups` next to the script. It contains the configuration, secrets, Synapse data, Caddy, Coturn and LiveKit configuration, and a consistent PostgreSQL dump. Keep important backup copies outside the VPS.

## Restore

Restore the most recent available archive:

```bash
sudo bash ./matrix-node.sh restore
```

Restore a specific archive:

```bash
sudo bash ./matrix-node.sh restore /path/to/matrix_backup_TIMESTAMP.tar.gz
```

If the current stack is running, the installer creates a safety backup before restoring the selected archive.

## Generated files

```text
.backups/             backup archives
.matrix-node-state/   run logs and internal state
.secrets.env          generated secrets
docker-compose.yml    generated container configuration
postgres/             PostgreSQL data
synapse/              Synapse configuration and data
caddy/                Caddy configuration and data
coturn/                Coturn certificates
livekit/               LiveKit configuration
```

Do not commit these generated files or directories to a public repository.

## Security

The project is designed for private deployments:

- public registration is disabled by default
- users can only be created by the administrator
- no administrator account is created automatically
- user passwords are requested interactively
- PostgreSQL and the Synapse backend are not exposed publicly
- TLS terminates at Caddy
- the firewall exposes only the required ports
- secrets and configuration files are created with restricted permissions.

Never publish:

```text
.secrets.env
private keys
TURN secret
LiveKit API secret
PostgreSQL password
Synapse signing key
backup archives
```

### Password handling limitation

The user password is not passed as an argument to the main script. During account creation, however, it is briefly passed to the internal `register_new_matrix_user` tool with its `-p` option.

This is accepted as a practical compromise for small private deployments. Environments with stronger security requirements should replace it with stdin-based input or another mechanism that prevents the password from appearing in a process argument list.

### System changes

During installation, the script may:

- install Docker, Docker Compose, and required system packages
- configure and enable UFW
- add firewall rules for the detected SSH port and Matrix services
- set `vm.swappiness`
- create `/swapfile` and an `/etc/fstab` entry on low-memory systems.

Review the script before running it and keep an independent backup of important data.

## Troubleshooting

### Caddy cannot obtain a certificate

Check DNS and HTTP connectivity:

```bash
dig +short matrix.example.org
curl -I http://matrix.example.org
```

The A record must point to the current VPS public address, and `80/tcp` must be reachable from the internet.

### Coturn does not listen on port 5349

```bash
ls -la ./coturn/certs/
ss -ltnp | grep 5349
```

The Coturn container must be able to read `DOMAIN.crt` and `DOMAIN.key`.

### Federation does not work

```bash
curl -fsS "https://matrix.example.org/.well-known/matrix/server"
curl -i "https://matrix.example.org/_matrix/federation/v1/version"
```

The first request should return `matrix.example.org:443`; the second should return Synapse version information.

### Messaging works, but calls do not

Check:

- Coturn on `3478/tcp`, `3478/udp`, and `5349/tcp`
- TURN relay range `49160-49200/udp`
- LiveKit on `7881/tcp` and `50000-50100/udp`
- the `/.well-known/matrix/client` response
- the `/livekit/jwt/*` and `/livekit/sfu/*` routes.

For a realistic test, place the devices on different networks, such as Wi-Fi and a mobile network.

## Updating

Create a backup before any manual update:

```bash
sudo bash ./matrix-node.sh backup
```

The recommended way to apply the current installer configuration is:

```bash
sudo bash ./matrix-node.sh install --force
sudo bash ./matrix-node.sh check
```

Images tagged `latest` may introduce incompatible changes. For stable operation, pin container versions with the supported environment variables.

## Client-side validation

After installation, validate:

- login with the selected Matrix client
- room creation and messaging
- voice and video calls
- calls over a mobile network
- TURN fallback
- federation between different homeservers.

These scenarios depend on specific clients, networks, and carriers and are outside the built-in installer health check.

## Removal

Create a backup first:

```bash
sudo bash ./matrix-node.sh backup
```

Stop the containers from the working directory:

```bash
docker compose down
```

Deleting the working directory destroys configuration, secrets, and service data. Ensure that a tested backup is stored elsewhere before removing anything.

## Disclaimer

This project is provided as-is, without warranties of operation, compatibility, or data preservation. The administrator is responsible for the server, domain, users, updates, backups, deployment security, and compliance with applicable law.

Before production use, review the script, verify DNS and firewall rules, create a backup, and test the restore process.
