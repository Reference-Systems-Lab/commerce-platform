# platform

The local environment for the whole commerce platform. Clone it, bootstrap it, bring it up,
and the storefront, admin, checkout, API, documentation, mail and observability all run at their own
local HTTPS addresses. It contains no business logic. Its job is to make the ecosystem easy to
start, run and verify.

## Responsibilities

- Starting and stopping the ecosystem with a handful of simple commands: bootstrap, up, down, reset,
  seed, logs and status
- The reverse proxy, local TLS, and routing each domain to its application
- Local infrastructure: PostgreSQL, Valkey (Redis-compatible), RabbitMQ, Mailpit and Meilisearch
- Local observability: logs, metrics, traces and dashboards
- Development configuration and secrets, generated rather than handed out
- Health checks across every service
- Integration and end-to-end tests for the whole ecosystem
- Recording which versions of each component are known to work together

## Local addresses

```text
https://rsl-commerce.test
https://api.rsl-commerce.test
https://admin.rsl-commerce.test
https://checkout.rsl-commerce.test
https://docs.rsl-commerce.test
https://design.rsl-commerce.test
https://mail.rsl-commerce.test
https://observe.rsl-commerce.test
```

Each address needs its own line in the hosts file, because hosts files do not support wildcards.
`make hosts` adds the missing ones. `api.rsl-commerce.test` serves the backend. Until an application
joins the stack, its address answers with a "not running yet" page; `rsl-commerce.test` shows a
placeholder until the storefront arrives.

## Getting started

You need Docker Desktop (WSL2 or macOS) or Docker Engine (Linux) with Compose 5 or newer, `make`,
`openssl` and `curl`. On Windows, clone into the WSL filesystem (such as `~/code`), not under `/mnt`.

```sh
make bootstrap   # secrets, certificates, and trust for the root certificate
make hosts       # adds the missing local addresses to your hosts file
make up          # starts everything and waits until it's healthy
make seed        # once: the development data (run it again after make reset)
```

Then open <https://rsl-commerce.test>, <https://api.rsl-commerce.test/v1/products> and
<https://mail.rsl-commerce.test>. The first `make up` downloads the applications' images from GHCR and
their Compose fragments from GitHub, so it needs network access. `make bootstrap` is safe
to run again at any time: it keeps your secrets and certificates and asks for nothing that's done.

## Commands

| Command | What it does |
| ------- | ------------ |
| `make bootstrap` | Checks prerequisites, writes `.env` and the Postgres secret, creates or renews the certificates, trusts the root, and lists missing hosts lines |
| `make up` | Starts the platform and waits until every service is healthy; `LOCAL=backend` builds the backend from `../backend` (or `BACKEND_SRC`) instead of pulling its image |
| `make seed` | Adds the development data (the backend's products). Safe to run again; `make up` never seeds |
| `make down` | Stops it and keeps the data |
| `make reset` | Stops it and deletes its data (asks first; `CONFIRM=yes` skips the question). Keeps `.env` and the certificates |
| `make status` | Service health, the certificate's days left, trust and the hosts file |
| `make doctor` | Checks this machine and checkout for problems, changing nothing |
| `make logs` | Follows the logs; `make logs s=postgres` for one service |
| `make smoke` | Checks the running platform end to end |
| `make lint` | Static checks and tests, as CI runs them |
| `make trust`, `make untrust` | Trusts the root certificate, or removes every root this platform created |
| `make hosts` | Adds the missing local addresses to the hosts file |

The services, on the internal `data` network: `postgres:5432` (user and database `commerce`),
`valkey:6379`, `rabbitmq:5672`, `mailpit:1025` for SMTP, and `meilisearch:7700`. Each needs its
credential, generated into `.env`: `POSTGRES_PASSWORD`, `VALKEY_PASSWORD`, `RABBITMQ_PASSWORD` (user
`commerce`) and `MEILI_MASTER_KEY`. The proxy sits on a separate `edge` network and can't reach
them. RabbitMQ's management UI is at <http://127.0.0.1:15672>.

## Applications

Each application runs from its own repository's `compose.platform.yaml`, which `compose.yaml`
includes at the commit of a release, together with this repository's wiring file
(`compose/compose.<app>.yaml`: the image pinned by digest, the networks and the start order) and env
file (`compose/<app>.env`). See [ADR 0002](docs/adr/0002-running-applications.md).

| Application | Services | Address |
| ----------- | -------- | ------- |
| backend | `backend-migrate` (applies migrations, then exits), `backend-api` | <https://api.rsl-commerce.test> |

**Updating an application** to release `vX.Y.Z`, in one pull request:

1. In `compose.yaml`, set the include to the commit the tag points to
   (`git ls-remote https://github.com/Reference-Systems-Lab/commerce-<app>.git 'refs/tags/vX.Y.Z^{}'`)
   and the comment to `# vX.Y.Z`.
2. In `compose/compose.<app>.yaml`, set every `image:` to `…:X.Y.Z@sha256:<digest>`
   (`docker buildx imagetools inspect ghcr.io/reference-systems-lab/commerce-<app>:X.Y.Z`).
3. Run `make lint`: it fails if the three disagree. When Dependabot opens the pull request with the
   new image, do step 1 in that pull request.

## What asks for permission

Two steps change your machine, and each asks once:

- **`make trust`.** The platform's own root certificate, which can only vouch for
  `rsl-commerce.test` addresses (never another site or an IP address).
  - WSL2: Windows asks you to confirm adding it to your user's certificate store. No administrator
    rights. Check the thumbprint the command prints, then choose Yes. Edge and Chrome use it.
  - macOS: `sudo` adds it to the System keychain, which Safari, Chrome and Firefox read.
  - Linux: `sudo` adds it to the system store, then `certutil` adds it to Chrome's and Firefox's
    databases (install `libnss3-tools` or `nss-tools` first).
- **`make hosts`.** It shows the change, then writes a block between `# BEGIN rsl-commerce` and
  `# END rsl-commerce` holding only the missing addresses, keeping a copy of the original as
  `hosts.rsl-commerce.bak`. On WSL2 that's Windows' hosts file, after one administrator (UAC)
  prompt; on macOS and Linux, `/etc/hosts` with `sudo`.

`make untrust` removes the root again. To remove the hosts lines, delete the block by hand.

## Troubleshooting

Start with `make doctor`: it checks Docker and Compose, the ports, disk space, `.env`, the
certificates, trust and the hosts file, and says what to do about each problem.

- **A certificate warning in the browser.** Run `make trust`, then restart the browser.
- **Still an error after fixing it.** The proxy sends HSTS for a day, so a browser that saw a broken
  certificate may refuse to let you continue. Clear it for the address: in Chrome or Edge open
  `chrome://net-internals/#hsts` (or `edge://net-internals/#hsts`) and delete the domain policy for
  `rsl-commerce.test`; in Firefox, forget the site from its history.
- **A credential stopped working.** Postgres and RabbitMQ keep the password from their first start
  in their data volume. If `.env` changed since, `make reset` starts the data over.

## Does not own

- Business logic, schemas or migrations. The backend owns those.
- What an application needs from infrastructure. Each application declares its own contract.
- Production infrastructure. Local services stand in for managed ones.

## Works with

- **Every application repository.** The platform runs each one and routes traffic to it.
- **backend.** The platform provides the database, cache, message broker, mail and search that the
  backend declares it needs.

## Git hooks

Run `.githooks/setup` once after cloning, and again when a pull changes it. It turns on the
committed hooks, which use [git-secrets](https://github.com/awslabs/git-secrets#installing-git-secrets)
to refuse any commit that contains a secret.

## Status

The walking skeleton: the proxy, local TLS, the infrastructure services and the backend run, with
`make smoke` and CI proving them. The decisions are in [ADR 0001](docs/adr/0001-platform-stack.md)
(the stack) and [ADR 0002](docs/adr/0002-running-applications.md) (running the applications).

## License

[MIT](LICENSE)
