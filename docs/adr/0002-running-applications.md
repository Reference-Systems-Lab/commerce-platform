# 2. Running the applications from their fragments

- **Status:** Accepted
- **Date:** 2026-10-08

## Context

The platform runs the infrastructure (ADR 0001); the applications are built and released in their own
repositories. Each application owns what it needs (its services, commands, health check and
configuration names), and the platform owns provisioning (images, networks, secrets, routing), with
neither reaching into the other's internals (AGENTS.md). The spike decided the shape
(commerce-platform#1 P-D1, P-D2); the backend is the first application to join
(commerce-platform#7, with commerce-backend#2 shipping its fragment and v0.1.0). Two probes on
Compose 5.5.1 confirmed the mechanism before it was built.

## Decision

- **The application's contract.** Each application repository ships `compose.platform.yaml`: its own
  services only, under its own name prefix, every platform-provided value as a required variable,
  hardened (non-root, read-only, no capabilities), with a health check, and no image, ports,
  networks, dependencies or infrastructure host names.
- **Fetched at a release's commit.** `compose.yaml` includes the fragment straight from the
  application's repository at the commit its release tag points to, with the release named in a
  comment (`…/commerce-backend.git#929b6f1…:compose.platform.yaml # v0.1.0`). A tag can move; a
  commit can't. The first `make up` needs network access to GitHub; Compose caches the file.
- **The platform's wiring.** In the same `include`, `compose/compose.<app>.yaml` pins the image by
  tag and digest from GHCR, puts each service on its networks (the API on `data` and `edge`, a
  migration on `data` only, so the proxy still reaches no data service), and sets the order (the
  backend's migration waits for Postgres; its API waits for the migration to complete). A committed
  `compose/<app>.env` gives the fragment its non-secret settings, such as a database URL without a
  password; secrets reach the application only as the platform's secret files.
- **Routing.** Each application's address gets its own `proxy/conf.d` file that proxies to the
  service through a variable (so the proxy starts while the application is down) and serves the
  "not running" page on 502 or 504. The proxy adds HSTS and the forwarding headers and nothing
  else; the application sets its own response headers.
- **One-shot services.** A service with its health check disabled that exits 0, such as
  `backend-migrate`, counts as ready for `make smoke` and `make status`.
- **Seeding is explicit.** `make seed` runs the backend's idempotent `seed` once; `make up` never
  seeds, so local edits to the data survive restarts. Bootstrap and the README say when to run it.
- **Local builds.** `make up LOCAL=<app>` adds `compose/local/<app>.yaml`, which builds the
  application from `${<APP>_SRC:-../<app>}` instead of pulling its image.
- **Updating an application is one commit.** The include's commit and comment and the wiring's image
  tag and digest change together. `make lint` fails if the image tag and the include's release
  differ, or if the include's commit isn't what that release's tag points to. Dependabot bumps the
  image; the include is bumped by hand in the same pull request. A scheduled bump workflow is a
  later improvement.

## Alternatives

- **Copying each fragment into this repository.** No network needed, but the contract then lives in
  two places and drifts from the application.
- **Including the fragment from a sibling checkout by default.** It breaks for anyone who cloned
  only the platform, and makes the running version whatever happens to be checked out.
- **Pinning the include by tag.** Readable, but a tag can be moved after review; the commit plus a
  comment keeps it readable and fixed.
- **Image pins in environment variables.** Dependabot doesn't update images set through variables
  (P-D2).
- **Seeding on every `make up`.** One fewer step, but it overwrites local changes to the seeded
  products on each restart.
- **Running migrations inside the API's start-up.** Hides failures and races between replicas; a
  one-shot that `make up` waits for fails visibly.

## Consequences

- A contributor gets the released backend at `https://api.rsl-commerce.test` with `make up`, and the
  development products with one `make seed`.
- An application release changes nothing here until its pin is bumped, and the bump is reviewed as
  one pull request with lint proving the three pins agree.
- Dependabot pull requests for an application's image fail lint until someone bumps the include in
  the same pull request.
- `make lint` and the first `make up` need network access to GitHub; `make lint` also checks the
  release tag there.
- The storefront joins the same way, with its own fragment, wiring, env file and route.
- Container resource limits, when needed, belong in the wiring file.
