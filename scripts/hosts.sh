#!/bin/sh
# Points the platform's local addresses at 127.0.0.1 in the hosts file your browser uses.
#
#   sh scripts/hosts.sh           add the missing ones (make hosts): shows the change, then asks once to elevate
#   sh scripts/hosts.sh --check   list missing and conflicting addresses, changing nothing; exit 1 if any
#   sh scripts/hosts.sh --print   print the file make hosts would write, changing nothing
#
# It writes only a block between "# BEGIN rsl-commerce" and "# END rsl-commerce", holding the addresses
# found nowhere else in the file. Every byte outside the block stays as it was, line endings included.
# Before its first change it keeps a copy, hosts.rsl-commerce.bak, beside the file. If the file changes
# between reading and writing (Docker Desktop rewrites it at times), nothing is written. An address that
# points anywhere other than 127.0.0.1 is a conflict: it's reported, and left for you to fix.
#
# WSL2: the Windows hosts file, written by an elevated Windows PowerShell after one UAC prompt.
# macOS and Linux: /etc/hosts, written with sudo.
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. ./scripts/lib.sh

MODE=${1:-apply}
case $MODE in
  apply | --check | --print) ;;
  *) die "usage: sh scripts/hosts.sh [--check|--print]" ;;
esac

OS=$(platform_os)
WIN_HOSTS='C:\Windows\System32\drivers\etc\hosts'
if [ -n "${RSL_HOSTS_FILE:-}" ]; then
  HOSTS=$RSL_HOSTS_FILE # test hook: tests/hosts.test.sh points it at fixtures
  [ "$MODE" != apply ] || die "RSL_HOSTS_FILE is for --check and --print only."
elif [ "$OS" = wsl ]; then
  HOSTS=$(wslpath -u "$WIN_HOSTS")
else
  HOSTS=/etc/hosts
fi
[ -f "$HOSTS" ] || die "$HOSTS doesn't exist."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# One copy, read once: every decision below, and the final compare-and-swap, refer to these bytes.
cp "$HOSTS" "$tmp/base"

# The transform, in plain awk with no state. Reads the hosts file and, by mode:
#   report  one line per address: "ok <host>", "missing <host>" or "conflict <host> <ips>", or only
#           "damaged" when the BEGIN and END lines don't pair up
#   render  the file with the block rewritten (or appended), every other byte unchanged; exits 2 if damaged
# shellcheck disable=SC2016 # awk's own $ fields, not shell expansions
TRANSFORM='
BEGIN {
  n = split(names, want, " ")
  for (i = 1; i <= n; i++) wanted[want[i]] = 1
}
{
  raw[NR] = $0
  line = $0
  sub(/\r$/, "", line)
  if (NR == 1 && $0 ~ /\r$/) eol = "\r\n"
  if (line == "# BEGIN rsl-commerce") {
    if (begin) damaged = 1
    begin = NR
    next
  }
  if (line == "# END rsl-commerce") {
    if (!begin || end) damaged = 1
    end = NR
    next
  }
  sub(/#.*/, "", line)
  count = split(line, field)
  for (i = 2; i <= count; i++) {
    name = tolower(field[i])
    if (!(name in wanted)) continue
    if (field[1] == ip) mapped[name] = 1
    else conflict[name] = conflict[name] " " field[1]
    if (!begin || end) outside[name] = 1
  }
}
END {
  if (begin && !end) damaged = 1
  if (mode == "report") {
    if (damaged) { print "damaged"; exit }
    for (i = 1; i <= n; i++) {
      h = want[i]
      if (h in conflict) print "conflict", h, substr(conflict[h], 2)
      else if (h in mapped) print "ok", h
      else print "missing", h
    }
    exit
  }
  if (damaged) exit 2
  if (eol == "") eol = "\n"
  block = ""
  for (i = 1; i <= n; i++) if (!(want[i] in outside)) block = block ip " " want[i] eol
  if (block != "") {
    block = "# BEGIN rsl-commerce" eol \
      "# Local addresses of the rsl-commerce platform, written by its make hosts." eol \
      block "# END rsl-commerce" eol
  }
  for (i = 1; i <= NR; i++) {
    if (begin && i >= begin && i <= end) {
      if (i == begin) printf "%s", block
      continue
    }
    printf "%s", raw[i]
    if (i < NR || final_eol) printf "\n"
  }
  if (!begin && block != "") {
    if (NR && !final_eol) printf "%s", eol
    printf "%s", block
  }
}
'

# transform <report|render>: run the transform on the copy.
transform() {
  if [ -z "$(tail -c 1 "$tmp/base")" ]; then final_eol=1; else final_eol=0; fi
  LC_ALL=C awk -v mode="$1" -v names="$RSL_HOSTS" -v ip=127.0.0.1 -v final_eol="$final_eol" "$TRANSFORM" "$tmp/base"
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

if [ "$MODE" = --print ]; then
  transform render || die "the rsl-commerce block in $HOSTS is damaged: fix its BEGIN and END lines by hand."
  exit 0
fi

transform report >"$tmp/report"
if grep -qx damaged "$tmp/report"; then
  die "the rsl-commerce block in $HOSTS is damaged: its '# BEGIN rsl-commerce' and '# END rsl-commerce' lines don't pair up. Fix them by hand."
fi
total=$(wc -l <"$tmp/report" | tr -d ' ')
present=$(grep -c '^ok ' "$tmp/report" || true)
missing=$(sed -n 's/^missing //p' "$tmp/report" | tr '\n' ' ' | sed 's/ $//')
conflicts=$(grep '^conflict ' "$tmp/report" || true)

info "Hosts file: $HOSTS"
[ "$present" -eq 0 ] || ok "$present of $total addresses point at 127.0.0.1"
[ -z "$missing" ] || warn "missing: $missing"
if [ -n "$conflicts" ]; then
  printf '%s\n' "$conflicts" | while read -r _ host ips; do
    warn "$host points at $ips instead. make hosts never changes lines outside its block: fix that line by hand."
  done
fi

if [ "$MODE" = --check ]; then
  [ -z "$missing" ] || info "Run 'make hosts' to add the missing addresses."
  [ -z "$missing" ] && [ -z "$conflicts" ]
  exit
fi

if [ -z "$missing" ]; then
  ok "Nothing to add."
  [ -z "$conflicts" ]
  exit
fi

transform render >"$tmp/new"
info "make hosts will change it like this (line endings not shown):"
tr -d '\r' <"$tmp/base" >"$tmp/base.txt"
tr -d '\r' <"$tmp/new" >"$tmp/new.txt"
diff -u "$tmp/base.txt" "$tmp/new.txt" | sed '1,2d' || true

# --- WSL2: an elevated Windows PowerShell writes the file --------------------------------------------

# Runs elevated, inline: no script file an unelevated process could swap. The @...@ tokens are
# replaced with base64 or hex, so no value needs quoting.
PS_ELEVATED=$(
  cat <<'EOF'
$ErrorActionPreference = 'Stop'
$hosts = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('@HOSTS@'))
$staged = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('@STAGED@'))
$sha = [Security.Cryptography.SHA256]::Create()
function Hex([byte[]] $bytes) { -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) }
$new = [IO.File]::ReadAllBytes($staged)
if ((Hex $new) -ne '@STAGED_SHA@') { exit 4 }
$old = [IO.File]::ReadAllBytes($hosts)
if ((Hex $old) -ne '@BASE_SHA@') { exit 3 }
$backup = $hosts + '.rsl-commerce.bak'
if (-not (Test-Path -LiteralPath $backup)) { [IO.File]::WriteAllBytes($backup, $old) }
[IO.File]::WriteAllBytes($hosts, $new)
try { Clear-DnsClientCache } catch { }
exit 0
EOF
)

# Starts the elevated PowerShell by its absolute path and waits for it: the UAC prompt appears here.
PS_ELEVATE=$(
  cat <<'EOF'
$exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
try {
  $p = Start-Process -FilePath $exe -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $env:RSL_ELEVATED -Verb RunAs -WindowStyle Hidden -Wait -PassThru
  $p.ExitCode
} catch { 'declined' }
EOF
)

wsl_apply() {
  # Stage the new file in Windows' temp folder, so the elevated process reads it from a Windows path.
  # The path comes back base64-encoded, because the console would mangle any non-ASCII characters.
  staged_b64=$(powershell '[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetTempFileName()))')
  staged=$(wslpath -u "$(printf '%s' "$staged_b64" | base64 -d)")
  cat "$tmp/new" >"$staged"
  script=$(printf '%s\n' "$PS_ELEVATED" | sed \
    -e "s|@HOSTS@|$(printf '%s' "$WIN_HOSTS" | base64 -w0)|" \
    -e "s|@STAGED@|$staged_b64|" \
    -e "s|@BASE_SHA@|$(sha256 "$tmp/base")|" \
    -e "s|@STAGED_SHA@|$(sha256 "$staged")|")
  info "Windows asks for administrator approval (UAC) once, to write the hosts file."
  result=$(powershell "$PS_ELEVATE" RSL_ELEVATED="$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)")
  rm -f "$staged"
  case $result in
    0) ;;
    3) die "the hosts file changed while you were deciding (Docker Desktop rewrites it at times), so nothing was written. Run 'make hosts' again." ;;
    4) die "the staged copy changed before it was written, so nothing was written. Run 'make hosts' again." ;;
    declined) die "the administrator prompt was declined, so nothing changed." ;;
    *) die "the elevated write failed (it answered '$result')." ;;
  esac
}

# --- macOS and Linux: sudo writes the file ---------------------------------------------------------

# Runs as root, with the same compare-and-swap. Arguments: the hosts file, the staged file, the hash the
# hosts file had when it was read, and the staged file's hash.
ROOT_WRITE=$(
  cat <<'EOF'
set -eu
hosts=$1 staged=$2 base=$3 want=$4
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
copy=$(mktemp)
trap 'rm -f "$copy"' EXIT
cat "$staged" >"$copy"
[ "$(sha "$copy")" = "$want" ] || exit 4
[ "$(sha "$hosts")" = "$base" ] || exit 3
[ -e "$hosts.rsl-commerce.bak" ] || cp -p "$hosts" "$hosts.rsl-commerce.bak"
cat "$copy" >"$hosts"
if [ "$(uname -s)" = Darwin ]; then
  dscacheutil -flushcache || true
  killall -HUP mDNSResponder || true
fi
EOF
)

unix_apply() {
  info "sudo asks for your password to write $HOSTS."
  code=0
  sudo sh -c "$ROOT_WRITE" sh "$HOSTS" "$tmp/new" "$(sha256 "$tmp/base")" "$(sha256 "$tmp/new")" || code=$?
  case $code in
    0) ;;
    3) die "$HOSTS changed while you were deciding, so nothing was written. Run 'make hosts' again." ;;
    4) die "the staged copy changed before it was written, so nothing was written. Run 'make hosts' again." ;;
    *) die "writing $HOSTS failed (exit $code)." ;;
  esac
}

case $OS in
  wsl) wsl_apply ;;
  macos | linux) unix_apply ;;
  *) die "unsupported system: add these lines to your hosts file by hand." ;;
esac
cmp -s "$tmp/new" "$HOSTS" || die "$HOSTS doesn't hold the expected content after writing. Check it, and $HOSTS.rsl-commerce.bak."
ok "Added $missing. The original is kept as $HOSTS.rsl-commerce.bak."
