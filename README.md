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
`make hosts` adds the missing ones. Until an application joins the stack, its address answers with
a "not running yet" page; `rsl-commerce.test` shows a placeholder until the storefront arrives.

## Getting started

You need Docker Desktop (WSL2 or macOS) or Docker Engine (Linux) with Compose 5 or newer, `make`,
`openssl` and `curl`. On Windows, clone into the WSL filesystem (such as `~/code`), not under `/mnt`.

```sh
make bootstrap   # secrets, certificates, and trust for the root certificate
make hosts       # adds the missing local addresses to your hosts file
make up          # starts everything and waits until it's healthy
```

Then open <https://rsl-commerce.test> and <https://mail.rsl-commerce.test>. `make bootstrap` is safe
to run again at any time: it keeps your secrets and certificates and asks for nothing that's done.

## Commands

| Command | What it does |
| ------- | ------------ |
| `make bootstrap` | Checks prerequisites, writes `.env` and the Postgres secret, creates or renews the certificates, trusts the root, and lists missing hosts lines |
| `make up` | Starts the platform and waits until every service is healthy |
| `make down` | Stops it and keeps the data |
| `make reset` | Stops it and deletes its data (asks first; `CONFIRM=yes` skips the question). Keeps `.env` and the certificates |
| `make status` | Service health, the certificate's days left, trust and the hosts file |
| `make doctor` | Checks this machine and checkout for problems, changing nothing |
| `make logs` | Follows the logs; `make logs s=postgres` for one service |
| `make smoke` | Checks the running platform end to end |
| `make lint` | Static checks and tests, as CI runs them |
| `make trust`, `make untrust` | Trusts the root certificate, or removes every root this platform created |
| `make hosts` | Adds the missing local addresses to the hosts file |

The services, from inside the Compose network: `postgres:5432` (user and database `commerce`),
`valkey:6379`, `rabbitmq:5672`, `mailpit:1025` for SMTP, and `meilisearch:7700`. The passwords and
the Meilisearch key are generated into `.env`. RabbitMQ's management UI is at
<http://127.0.0.1:15672>.

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

Run `.githooks/setup` once after cloning. It turns on the committed hooks, which use
[git-secrets](https://github.com/awslabs/git-secrets#installing-git-secrets) to refuse any commit
that contains a secret.

## Status

The walking skeleton: the proxy, local TLS and the infrastructure services run, with `make smoke`
and CI proving them. No application has joined yet. The decisions behind the stack are in
[ADR 0001](docs/adr/0001-platform-stack.md).

## License

[MIT](LICENSE)
