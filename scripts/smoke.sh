#!/bin/sh
# Checks the running platform end to end: every address over TLS, each service over the network the
# applications will use, the containers' hardening, and that `make down` keeps data. Run `make smoke`
# after `make up`; it exits 1 when any check fails.
#
# Requests go to 127.0.0.1 with curl --resolve and trust only this platform's root, so the checks need
# neither the hosts file nor a trust store (CI has neither). Everything it writes it removes again.
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. ./scripts/lib.sh

need_cmd curl "Install curl."
need_cmd docker "Install Docker Desktop or Docker Engine."
CA=certs/ca/rootCA.pem
if [ ! -f "$CA" ] || [ ! -f .env ]; then
  die "the certificates or .env are missing. Run 'make bootstrap' first."
fi

# Every service is up and healthy, or is a one-shot that completed (backend-migrate).
not_ready=
for service in $(docker compose config --services); do
  container=$(docker compose ps --all --quiet "$service")
  if [ -z "$container" ]; then
    state="not created"
  else
    state=$(container_state "$container")
  fi
  case $state in healthy | completed) ;; *) not_ready="$not_ready${not_ready:+; }$service: $state" ;; esac
done
[ -z "$not_ready" ] || die "not every service is ready ($not_ready). Run 'make up' first."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The pages the proxy serves itself carry this policy (proxy/snippets/static-page-headers.conf).
CSP="default-src 'none'; style-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
marker=smoke-$(od -An -tx1 -N6 /dev/urandom | tr -d ' \n')

checks=0
failures=0
problems=

# want <what> <expected> <actual>: note a problem when actual differs from expected.
want() {
  [ "$3" = "$2" ] || problems="$problems${problems:+; }$1: expected '$2', got '$3'"
}

# check <description>: report the problems noted since the last check as one pass or fail line.
check() {
  checks=$((checks + 1))
  if [ -z "$problems" ]; then
    ok "$1"
  else
    fail "$1 ($problems)"
    failures=$((failures + 1))
  fi
  problems=
}

# tls <host> <curl args...>: a request to https://<host> through the proxy, trusting only our root.
tls() {
  tls_host=$1
  shift
  curl -sS --max-time 10 --cacert "$CA" --resolve "$tls_host:443:127.0.0.1" "$@"
}

# exit_code <command...>: the command's exit code, without stopping the script.
exit_code() {
  code=0
  "$@" >/dev/null 2>&1 || code=$?
  echo "$code"
}

info "Addresses"
for host in $RSL_HOSTS; do
  path=
  case $host in
    "$RSL_DOMAIN") status=200 page="The local platform is running" what="the placeholder" csp=$CSP ;;
    "mail.$RSL_DOMAIN") status=200 page="<title>Mailpit</title>" what="Mailpit" csp= ;;
    "api.$RSL_DOMAIN") status=200 page='{"status":"ok"}' what="the backend's health" csp='' path=health ;;
    *) status=503 page="running yet" what="the 503 page" csp=$CSP ;;
  esac
  : >"$tmp/headers"
  : >"$tmp/body"
  want response "$status HTTP/2" "$(tls "$host" -D "$tmp/headers" -o "$tmp/body" -w '%{http_code} HTTP/%{http_version}' "https://$host/$path" 2>&1 || true)"
  want HSTS "max-age=86400; includeSubDomains" "$(tr -d '\r' <"$tmp/headers" | sed -n 's/^strict-transport-security: //p')"
  [ -z "$csp" ] || want CSP "$csp" "$(tr -d '\r' <"$tmp/headers" | sed -n 's/^content-security-policy: //p')"
  if [ "$host" = "api.$RSL_DOMAIN" ]; then
    # The backend's own headers pass through the proxy unchanged.
    want nosniff nosniff "$(tr -d '\r' <"$tmp/headers" | sed -n 's/^x-content-type-options: //p')"
    want cache-control no-store "$(tr -d '\r' <"$tmp/headers" | sed -n 's/^cache-control: //p')"
  fi
  grep -qF "$page" "$tmp/body" || problems="$problems${problems:+; }page: '$page' not found"
  want "http://$host/x?y=1" "301 https://$host/x?y=1" \
    "$(curl -sS --max-time 10 --resolve "$host:80:127.0.0.1" -o /dev/null -w '%{http_code} %{redirect_url}' "http://$host/x?y=1" 2>&1 || true)"
  check "$host: $status over HTTP/2 with HSTS, $what, and http:// redirects"
done

# -k, so a refusal shows as curl's handshake error (35) rather than a certificate error.
want "curl exit" 35 "$(exit_code curl -sk --max-time 10 --resolve "unknown.$RSL_DOMAIN:443:127.0.0.1" "https://unknown.$RSL_DOMAIN/")"
check "An unknown name: the TLS handshake is refused"
want "curl exit" 35 "$(exit_code curl -sk --max-time 10 https://127.0.0.1/)"
check "No name (no SNI): the TLS handshake is refused"
want "curl exit" 52 "$(exit_code curl -s --max-time 10 --resolve unknown.example:80:127.0.0.1 http://unknown.example/)"
check "Plain HTTP to an unknown name: closed without a response"

info "Services, reached by name over the Compose network as the applications will"

# sql <statement>: run it over TCP as commerce, with the password from the Compose secret.
sql() {
  # shellcheck disable=SC2016 # expanded by the container's shell
  docker compose exec -T postgres sh -c \
    'PGPASSWORD=$(cat /run/secrets/postgres_password) psql -h postgres -U commerce -d commerce -v ON_ERROR_STOP=1 -qtAc "$1"' \
    sh "$1"
}
login=$(sql 'SELECT 1' 2>&1 || true)
want login 1 "$login"
check "Postgres: commerce logs in over TCP with the generated password"
case $login in
  *"password authentication failed"*) warn "The postgres volume holds an older password than .env. 'make reset' starts fresh." ;;
esac
refused=$(docker compose exec -T postgres psql "postgresql://commerce:wrong-password@postgres/commerce" -qtAc 'SELECT 1' 2>&1 || true)
case $refused in *"password authentication failed"*) refused=refused ;; esac
want "wrong password" refused "$refused"
check "Postgres: a wrong password is refused"

# shellcheck disable=SC2016 # expanded by the container's shell, so the password stays off the command line
want "with the password" PONG "$(docker compose exec -T valkey sh -c \
  'VALKEYCLI_AUTH="$(sed -n "s/^requirepass //p" /run/secrets/valkey_config)" valkey-cli -h valkey ping' 2>&1 || true)"
want "without it" "NOAUTH Authentication required." "$(docker compose exec -T valkey valkey-cli -h valkey ping 2>&1 || true)"
check "Valkey: valkey-cli -h valkey answers only with the password"

# rabbit <curl args...>: the management API as commerce. The password goes in on stdin, not the command line.
rabbit() {
  printf 'user = "commerce:%s"\n' "$(env_get RABBITMQ_PASSWORD)" | curl -sS --max-time 10 -K - "$@"
}
queue=http://127.0.0.1:15672/api/queues/%2F/smoke.default-type
rabbit -X DELETE -o /dev/null "$queue" >/dev/null 2>&1 || true # left over from an interrupted run
declared=$(rabbit -X PUT -o /dev/null -w '%{http_code}' -H 'content-type: application/json' -d '{"durable":true}' "$queue" 2>&1 || true)
want declare 201 "$declared"
want type quorum "$(rabbit "$queue" 2>/dev/null | sed -n 's/.*"type":"\([^"]*\)".*/\1/p')"
want delete 204 "$(rabbit -X DELETE -o /dev/null -w '%{http_code}' "$queue" 2>&1 || true)"
check "RabbitMQ: a queue declared without a type is a quorum queue"
# From another container, as the backend will connect. The postgres image has bash for /dev/tcp.
want "AMQP connect" yes "$(docker compose exec -T postgres bash -c 'exec 3<>/dev/tcp/rabbitmq/5672 && echo yes' 2>&1 || true)"
check "RabbitMQ: AMQP answers at rabbitmq:5672 from another container"
[ "$declared" != 401 ] || warn "RabbitMQ refused the password in .env. 'make reset' starts fresh."

mail_api=https://mail.$RSL_DOMAIN/api/v1
printf 'From: smoke@%s\r\nTo: dev@%s\r\nSubject: %s\r\n\r\nSent by scripts/smoke.sh, which deletes it again.\r\n' \
  "$RSL_DOMAIN" "$RSL_DOMAIN" "$marker" |
  docker compose exec -T mailpit /mailpit sendmail -S mailpit:1025 -f "smoke@$RSL_DOMAIN" "dev@$RSL_DOMAIN" >/dev/null 2>&1 ||
  problems="sendmail to mailpit:1025 failed"
id=$(tls "mail.$RSL_DOMAIN" "$mail_api/search?query=subject:$marker" 2>/dev/null | sed -n 's/.*"ID":"\([^"]*\)".*/\1/p')
# mailpit_write <method> <origin> <json>: an API write as a page on <origin> would send it.
mailpit_write() {
  tls "mail.$RSL_DOMAIN" -X "$1" -o /dev/null -w '%{http_code}' -H "Origin: $2" -H 'Content-Type: application/json' \
    -d "$3" "$mail_api/messages" 2>&1 || true
}
case $id in
  "" | *[!A-Za-z0-9]*) problems="$problems${problems:+; }the message didn't arrive in the API" ;;
  *)
    # Always with the message's ID: a write without IDs applies to every message.
    want "listed in /api/v1/messages" yes "$(tls "mail.$RSL_DOMAIN" "$mail_api/messages" 2>/dev/null | grep -q "$marker" && echo yes || echo no)"
    want "PUT from Mailpit's own page" 200 "$(mailpit_write PUT "https://mail.$RSL_DOMAIN" "{\"IDs\":[\"$id\"],\"Read\":true}")"
    want "PUT from another site" 403 "$(mailpit_write PUT https://example.com "{\"IDs\":[\"$id\"],\"Read\":true}")"
    want DELETE 200 "$(mailpit_write DELETE "https://mail.$RSL_DOMAIN" "{\"IDs\":[\"$id\"]}")"
    ;;
esac
check "Mailpit: mail sent to mailpit:1025 reaches the API, and the UI's writes work through the proxy"
want "WebSocket upgrade" 101 "$(tls "mail.$RSL_DOMAIN" --http1.1 -o /dev/null -w '%{http_code}' --max-time 3 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
  -H 'Sec-WebSocket-Key: c21va2UtY2hlY2sta2V5IQ==' -H "Origin: https://mail.$RSL_DOMAIN" "https://mail.$RSL_DOMAIN/api/events" 2>/dev/null || true)"
check "Mailpit: its live-update WebSocket opens through the proxy"

# meili <curl args...>: a request to meilisearch:7700 from inside its container; prints the status.
meili() {
  docker compose exec -T meilisearch curl -s -o /dev/null -w '%{http_code}' "$@" 2>&1 || true
}
want /health 200 "$(meili http://meilisearch:7700/health)"
want "/indexes without the key" 401 "$(meili http://meilisearch:7700/indexes)"
# shellcheck disable=SC2016 # expanded by the container's shell, so the key stays off the command line
want "/indexes with the master key" 200 "$(docker compose exec -T meilisearch sh -c \
  'printf "Authorization: Bearer %s\n" "$MEILI_MASTER_KEY" | curl -s -o /dev/null -w "%{http_code}" -H @- http://meilisearch:7700/indexes' \
  2>&1 || true)"
check "Meilisearch: /health is open and /indexes needs the master key"

info "Containers"
hardened="ro=true capdrop=[ALL] capadd=[] sec=[no-new-privileges:true] init=true privileged=false"
for container in $(docker compose ps --all --quiet); do
  line=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}} user={{.Config.User}} ro={{.HostConfig.ReadonlyRootfs}} capdrop={{.HostConfig.CapDrop}} capadd={{.HostConfig.CapAdd}} sec={{.HostConfig.SecurityOpt}} init={{.HostConfig.Init}} privileged={{.HostConfig.Privileged}}' "$container")
  service=${line%% *}
  rest=${line#* }
  user=${rest%% *}
  user=${user#user=}
  if printf '%s\n' "$user" | grep -Eq '^[1-9][0-9]*:[0-9]+$'; then shown="numeric, not root"; else shown=$user; fi
  want user "numeric, not root" "$shown"
  want settings "$hardened" "${rest#* }"
  check "$service: user $user, read-only, no capabilities, no-new-privileges, init"
done
want ports "127.0.0.1:15672 127.0.0.1:443 127.0.0.1:80" \
  "$(for container in $(docker compose ps --quiet); do docker port "$container"; done | sed 's/.* -> //' | sort | paste -sd' ' -)"
check "Published ports: only 127.0.0.1 80, 443 and 15672"
want "data is internal" true "$(docker network inspect "${RSL_PROJECT}_data" --format '{{.Internal}}' 2>&1 || true)"
want "edge is internal" true "$(docker network inspect "${RSL_PROJECT}_edge" --format '{{.Internal}}' 2>&1 || true)"
for service in postgres valkey rabbitmq meilisearch; do
  case $(docker compose exec -T proxy wget -q -T 2 -O /dev/null "http://$service/" 2>&1 || true) in
    *"bad address"*) ;;
    *) problems="$problems${problems:+; }the proxy can resolve $service" ;;
  esac
done
check "Networks: data and edge are internal, and the proxy can't reach postgres, valkey, rabbitmq or meilisearch"
want "the proxy reaches backend-api" '{"status":"ok"}' \
  "$(docker compose exec -T proxy wget -q -T 5 -O - http://backend-api:8080/health 2>&1 || true)"
want "backend-migrate networks" "data" "$(docker inspect --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$(docker compose ps --all --quiet backend-migrate)" | sed "s/${RSL_PROJECT}_//g; s/ $//")"
want "backend-api networks" "data edge" "$(docker inspect --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$(docker compose ps --all --quiet backend-api)" | sed "s/${RSL_PROJECT}_//g; s/ $//")"
check "The backend: the proxy reaches backend-api on edge; the migration is on data only"

# The catalog answers through the proxy. Its contents depend on make seed, so only the shape is checked.
want "GET /v1/products" "200 items" "$(tls "api.$RSL_DOMAIN" -o "$tmp/body" -w '%{http_code}' "https://api.$RSL_DOMAIN/v1/products" 2>&1 || true) $(grep -o '"items":\[' "$tmp/body" >/dev/null && echo items)"
check "api.$RSL_DOMAIN/v1/products: 200 with an items list"

info "Data"
sql "CREATE TABLE IF NOT EXISTS smoke_persistence (marker text); INSERT INTO smoke_persistence VALUES ('$marker')" \
  >/dev/null 2>&1 || problems="writing the row failed"
if make -s down >"$tmp/restart.log" 2>&1 && make -s up >>"$tmp/restart.log" 2>&1; then
  want row "$marker" "$(sql "SELECT marker FROM smoke_persistence WHERE marker = '$marker'" 2>&1 || true)"
else
  problems="$problems${problems:+; }make down or make up failed"
  cat "$tmp/restart.log" >&2
fi
sql 'DROP TABLE IF EXISTS smoke_persistence' >/dev/null 2>&1 || true
check "Postgres: a row survives make down and make up"

echo
if [ "$failures" -eq 0 ]; then
  info "All $checks checks passed."
else
  info "$failures of $checks checks failed."
  exit 1
fi
