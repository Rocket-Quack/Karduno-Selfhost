<div align="center">

<a href="https://karduno.com/">
  <img src="assets/karduno-self-hosted.png" alt="Karduno Self-Hosted – green wallet with a server icon" width="360">
</a>

# Karduno Self-Hosted

**Your customer loyalty program. On your server.**

Loyalty points, rewards, and campaigns – run on your own server.

[**karduno.com ↗**](https://karduno.com/)

</div>

---

## What is this?

Karduno is a customer loyalty program: points, rewards, and campaigns for your customers. It provides an administration and POS interface, a public API for building your own customer app, and background jobs.

This repository deploys Karduno on your own server using **prebuilt container images** – no access to the application source code or local builds required. It includes Docker Compose, automatic HTTPS via Caddy, and optional installer scripts.

## Requirements

- Linux (Ubuntu, Debian, Fedora) or Windows 10/11 with Docker Desktop running Linux containers
- Three different hostnames with A/AAAA records pointing to your server, for example `points.example.com` (customer portal), `admin.points.example.com` (administration/POS), and `api.points.example.com` (API)
- TCP ports 80 and 443 open and reachable
- Outbound access to the container registries and the certificate authority
- Docker with Compose v2 – the installer script can set this up for you

## Quick start (installer script)

The guided installer walks through the configuration, generates the secrets, checks the domains, downloads the images, and starts the stack.

**Linux/Bash:**

```bash
bash easy-install.sh
```

**Windows/PowerShell:**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\easy-install.ps1
```

Run the command inside the cloned repository. The wizard asks only for your three domains and the initial administrator.

## Manual setup (Docker Compose)

1. Install Docker with Compose v2 and clone this repository.
2. Copy `.env.example` to `.env` and fill in your domains and initial administrator.
3. Generate the two secret files:

```bash
mkdir -p secrets && chmod 700 secrets
umask 077
od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > secrets/postgres_password
od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > secrets/jwt_secret
chmod 600 .env secrets/postgres_password secrets/jwt_secret
```

4. Download the images and start the stack:

```bash
docker compose pull
docker compose up -d --wait --wait-timeout 300
docker compose ps
```

On Windows, use the installer script above – it handles secret generation for you.

## After installation

| Endpoint | Example |
| --- | --- |
| Administration | `https://admin.points.example.com` |
| Customer portal (optional) | `https://points.example.com` |
| API | `https://api.points.example.com/api/v1` |
| API health | `https://api.points.example.com/api/health` |

The API is additionally reachable under `/api/v1` on the portal and
administration domains; the dedicated API domain is the canonical base URL
used for app integrations, POS webhooks, and links in e-mails.

Sign in with the initial administrator, then configure email delivery and test customer registration.

## Networking

The stack creates its own Docker network on `172.30.80.0/24`, with Caddy pinned to `172.30.80.2` so the API can trust it as the reverse proxy for client IPs and rate limits. If that range is already in use on the host – a VPN, VM host interface, or another Compose network – Compose fails with an address error, or host routing breaks. Set a free range in `.env`:

```
NETWORK_SUBNET=172.31.80.0/24
NETWORK_DYNAMIC_RANGE=172.31.80.128/25
PROXY_IP=172.31.80.2
```

`PROXY_IP` must be an address inside `NETWORK_SUBNET` and outside `NETWORK_DYNAMIC_RANGE`.

## Components and images

| Component | Image | Purpose |
| --- | --- | --- |
| API and worker | `ghcr.io/rocket-quack/osspoints/osspoints-api:latest` | Backend and background jobs |
| Admin | `ghcr.io/rocket-quack/osspoints/osspoints-admin:latest` | Administration and POS |
| Portal | `ghcr.io/rocket-quack/osspoints/osspoints-portal:latest` | Customer portal |
| PostgreSQL | `postgres:16` | Application data |
| Redis | `redis:7` | Job queue |
| Caddy | `caddy:2` | Reverse proxy and HTTPS |

The public images use `latest`. During normal operation only Caddy publishes host ports; all data is stored in Docker volumes.

This repository contains no application source code. The [MIT license](LICENSE) covers the files published here; it does not define the license of the separately distributed images.
