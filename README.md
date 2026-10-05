# platform

The local environment for the whole commerce platform. Clone it, bootstrap it, bring it up,
and the storefront, admin, checkout, API, documentation, mail and observability all run at their own
local HTTPS addresses. It contains no business logic. Its job is to make the ecosystem easy to
start, run and verify.

## Responsibilities

- Starting and stopping the ecosystem with a handful of simple commands: bootstrap, up, down, reset,
  seed, logs and status
- The reverse proxy, local TLS, and routing each domain to its application
- Local infrastructure: PostgreSQL, Redis, RabbitMQ, Mailpit and Meilisearch
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
https://mail.rsl-commerce.test
https://observe.rsl-commerce.test
```

Each address needs its own line in the hosts file, because hosts files do not support wildcards.

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

Planning. No code yet.

## License

[MIT](LICENSE)
