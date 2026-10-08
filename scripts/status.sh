#!/bin/sh
# Shows what's running and whether the local addresses work: each service's health, the certificate's
# days left, whether your browsers trust the root, and any address missing from the hosts file.
# Changes nothing. Run `make doctor` to diagnose a problem.
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. ./scripts/lib.sh

info "Services"
if [ ! -f .env ]; then
  warn "not set up yet. Run 'make bootstrap', then 'make up'."
elif ! docker info >/dev/null 2>&1; then
  warn "Docker isn't running."
else
  # Placeholder credentials, as in the Makefile: listing creates nothing, and must work with an incomplete .env.
  services=$(RABBITMQ_PASSWORD=unused MEILI_MASTER_KEY=unused docker compose ps --all --format '{{.Service}} {{.State}} {{.Health}}')
  if [ -z "$services" ]; then
    warn "not running. Run 'make up'."
  else
    printf '%s\n' "$services" | while read -r service state health; do
      if [ "$state" = running ] && [ "${health:-healthy}" = healthy ]; then
        ok "$service: running, healthy"
      else
        warn "$service: $state${health:+, $health}"
      fi
    done
  fi
fi

info "Certificate and trust"
if [ -f certs/leaf/cert.pem ] && [ -f certs/ca/rootCA.pem ]; then
  days=$(cert_days_left certs/leaf/cert.pem)
  if [ "$days" -lt 30 ]; then warn "certificate: $days days left. 'make bootstrap' reissues it."; else ok "certificate: $days days left"; fi
  if sh scripts/trust.sh check >/dev/null 2>&1; then ok "trusted: yes"; else warn "trusted: no. Run 'make trust'."; fi
else
  warn "no certificates yet. Run 'make bootstrap'."
fi

info "Hosts file"
hosts=$(sh scripts/hosts.sh --check 2>&1 || true)
printf '%s\n' "$hosts" | sed -n 's/^\(  ok    \)/\1/p; s/^\(  warn  \)/\1/p; s/^error: /  warn  /p'

info "Addresses"
info "  https://rsl-commerce.test        placeholder until the storefront joins"
info "  https://mail.rsl-commerce.test   Mailpit: every email the platform sends"
info "  http://127.0.0.1:15672           RabbitMQ management (user commerce, password in .env)"
