# 1. The local platform's stack

- **Status:** Accepted
- **Date:** 2026-10-08

## Context

The platform runs the commerce system on a developer's machine: a TLS proxy for eight local
addresses, and the infrastructure the backend declares it needs. It must start with few manual
steps on WSL2, macOS and Linux, need no real secret, and give each application the same hardened,
pinned services in CI as on a laptop. The spike (commerce-platform#1) compared the options and
decided P-D1 to P-D7; the walking skeleton (commerce-platform#2) built them. This record covers
both, including where the build had to differ from the spike.

## Decision

- **Orchestration.** Docker Compose 5 or newer alone (P-D1), started with `up --wait` so a command
  returns only when every service is healthy. `make` is a thin entry point over POSIX `sh` scripts
  that also run under GNU Make 3.81 and macOS's tools (P-D3).
- **Proxy.** nginx-unprivileged on the stable 1.30 alpine-slim line, pinned by digest (P-D6). One
  server block per address; any other name has its TLS handshake refused. HSTS is
  `max-age=86400; includeSubDomains`, short on purpose. Addresses whose application isn't in the
  stack yet answer a 503 page, and `rsl-commerce.test` serves a placeholder until the storefront
  joins. Mailpit gets the original `Host` header, because it refuses any other.
- **Local TLS.** `openssl` creates a root CA and one certificate for the eight addresses (P-D4); no
  mkcert. The root is `pathlen:0` and name-constrained: it permits only `rsl-commerce.test` and its
  subdomains, and excludes every IPv4 and IPv6 address. It may issue TLS server certificates only
  (`extendedKeyUsage = serverAuth`), so its key can't sign code or email that Windows, NSS or OpenSSL
  would accept. The root lasts 825 days, the certificate
  397. `make bootstrap` reissues the certificate when it has under 30 days left or no longer
  matches, and replaces the root (which must be trusted again) when it has under 427.
- **Trust, per system.** WSL2: Windows' `CurrentUser\Root`, with one confirmation and no
  administrator rights; WSL's own store is untouched. macOS: the System keychain, trusted for SSL
  only. Linux: the system store plus Chrome's and Firefox's NSS databases. `make untrust`
  removes only roots with this platform's organization.
- **Hosts file.** `make hosts` writes one marked block holding only the missing addresses, after
  one elevation. It compares hashes before writing, keeps a one-time backup, and leaves every other
  byte (and the line endings) alone.
- **Secrets.** `make bootstrap` generates every credential as `rsldev_<hex>` into a mode-600 `.env`
  (P-D5), keeps them on every rerun, and refuses to replace one a data volume still holds. Postgres
  and Valkey read theirs from file-sourced Compose secrets, never from a command line.
- **Services.** PostgreSQL 18, Valkey 9.1 instead of Redis, RabbitMQ 4.3 with quorum queues by
  default, Mailpit and Meilisearch (the MIT community build) (P-D7). Every container runs as a
  numeric non-root user, read-only, with no capabilities, `no-new-privileges` and `init`. Mailpit
  and Meilisearch are two-line derived images, built locally and never pulled by name. Only
  `127.0.0.1` ports 80, 443 and 15672 are published. Every service needs a credential, Valkey
  included (D-13).
- **Networks (D-13).** `edge` holds the proxy and Mailpit's UI. `data` is internal (no route out) and
  holds Postgres, Valkey, RabbitMQ, Meilisearch and Mailpit's SMTP, so the proxy can't reach any data
  service. RabbitMQ also joins a small `rabbitmq-ui` network, only because an internal network can't
  publish its management port.
- **Pins and checks.** Every image, base image and action is pinned by digest or commit SHA, and
  Dependabot updates them after a 7-day cooldown, holding nginx to its stable line and Postgres to
  major 18. `make lint` and `make smoke` are what CI runs.

### Where the build differs from the spike

- **The Postgres secret is file-sourced.** P-D5 called for a Compose secret; Compose 5 refuses a
  secret sourced from the environment in a read-only service ("`file` is the sole supported
  option"). The file, `secrets/postgres_password`, is written from `.env` by bootstrap.
- **The certificate's key and the secret file are mode 0644.** Compose bind-mounts both, and
  ignores ownership and mode for file secrets, so the containers' non-root users (101 for the
  proxy, 999 for Postgres) can read them only if everyone can. Both sit in gitignored directories
  on a single-user machine, and the key belongs to a short-lived certificate the root constrains.
  The root's key stays 0600 in a 0700 directory and is never mounted.
- **IPv6 is excluded from the root in the expanded form.** `openssl` rejects the short `IP:::/0`;
  the constraint is `excluded;IP:0:0:0:0:0:0:0:0/0:0:0:0:0:0:0:0`.
- **Windows trust adds the root from memory.** P-D4 named `Import-Certificate`, which reads a file.
  The bytes are checked against the thumbprint the user is shown, then added through the same store
  API with no file in between, so nothing can swap the certificate before Windows asks. Same store,
  same confirmation.
- **No NSS on macOS.** P-D4 trusted the root in NSS as well. Firefox on macOS reads roots from the
  System keychain as enterprise roots, so the keychain alone covers Safari, Chrome and Firefox.

## Alternatives

- **mkcert.** Its root can't be name-constrained, so a leaked root key could intercept any site.
  Its last release is from 2022-04-26, and it misses Chrome's newer Linux NSS path.
- **Caddy or Traefik as the proxy.** Caddy was the runner-up but needs `NET_BIND_SERVICE` to bind
  443 as non-root, an exception to the hardening every other container keeps. Traefik would need
  its file provider, giving up the label discovery that makes it attractive.
- **Caddy's internal CA or step-ca.** Both add a running service to do what one `openssl` script
  does once.
- **Tilt over Compose; just, Task or mise over Make.** Tilt adds a second CLI and UI for what
  Compose's profiles and `watch` already do. just was the runner-up runner; Task and mise are
  heavier and need template escaping around Docker's `{{ }}`.
- **Redis 8.** Valkey is BSD-licensed, matches what managed clouds now offer, and passed every
  operation the backend's client makes.
- **An environment-sourced secret, or a root-owned key readable by group.** Compose refuses the
  first for read-only services; the second needs `chown` to the containers' users, which means root
  on the host.
- **Valkey without a password on one shared network** (the spike's choice). Anything that joins the
  project network, a frontend or a compromised proxy, could then read and rewrite the cache, rate
  limits and locks, while every other service needed a credential.
- **A long HSTS policy.** A cached policy turns any later certificate problem into an error the
  browser won't let you click through.

## Consequences

- One `make bootstrap`, one `make hosts` and one `make up` give a trusted
  `https://rsl-commerce.test` on WSL2: one certificate confirmation and one elevation prompt, both
  only the first time. Later bootstraps ask for nothing.
- The name constraint was tested where it matters on WSL2: `openssl verify`, a Windows
  `X509Chain` (`HasNotPermittedNameConstraint`), Edge and Chrome all refuse a `localhost`
  certificate the root signed. A client that ignores name constraints would accept such a
  certificate, so for that client the root's key would act as an interception key for TLS (and only
  TLS: the root's own usage limit still applies). The key never leaves `certs/ca`.
- Changing a credential means `make reset`, which deletes the data volumes, because Postgres and
  RabbitMQ store their first password in their volumes.
- The trust and hosts paths for macOS and Linux are written and linted but not yet run on those
  systems; CI runs the CA and hosts tests on macOS.
- Each application that joins the stack replaces its 503 server block with its own route, and
  declares its own infrastructure needs; the platform provisions them. A service that uses the
  infrastructure joins `data` (and `edge` if the proxy routes to it), and connects to Valkey with
  `VALKEY_PASSWORD`; a frontend joins only `edge`.
