# Agent instructions: platform

The platform runs the ecosystem locally. It provisions infrastructure and never contains business
logic. Read the root [`AGENTS.md`](../AGENTS.md) as well; this file wins where the two conflict.

## Boundaries

- Applications own their contract with infrastructure, meaning what they need and how they are
  configured. The platform owns provisioning that infrastructure locally. Do not move either
  responsibility across.
- No application code, schemas, migrations or domain rules belong here.
- Local is not production. Never present the local setup as production architecture.

## Rules

- A new contributor should reach a working environment with as few manual steps as possible.
  Adding a manual step needs a strong reason.
- Development secrets only. Running the platform must never require a real secret.
- Every service added must meet a real need of the system.
- Before an infrastructure change opens its pull request, it gets two checks. First, independent
  read-only reviewers go over it: security, containers and proxy, shell portability, and acceptance
  coverage. Second, a rehearsal from nothing: `make reset`, then `make bootstrap` and `make up` on a
  clean checkout. Step-by-step checks miss what these catch.
