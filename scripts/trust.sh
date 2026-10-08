#!/bin/sh
# Trusts the platform's root certificate where your browsers look for it, or removes it again. Only the
# root (certs/ca/rootCA.pem) is ever trusted; its key never leaves certs/ca.
#
#   sh scripts/trust.sh           trust the current root (make trust); does nothing when it already is
#   sh scripts/trust.sh untrust   remove every root this platform created, and nothing else (make untrust)
#   sh scripts/trust.sh check     exit 0 when the current root is trusted (make status, make doctor)
#
# WSL2   Windows' CurrentUser\Root store, which Edge and Chrome on Windows use. Windows asks you to
#        confirm in one dialog and needs no administrator rights. WSL's own Linux store isn't touched.
# macOS  the System keychain (sudo), which Safari and Chrome read, and Firefox reads as an enterprise root.
# Linux  the system store (sudo), plus the NSS databases of Chrome and Firefox when certutil is installed.
set -eu
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. ./scripts/lib.sh

ROOT=certs/ca/rootCA.pem
MODE=${1:-trust}
case $MODE in
  trust | untrust | check) ;;
  *) die "usage: sh scripts/trust.sh [trust|untrust|check]" ;;
esac

THUMBPRINT=
if [ "$MODE" != untrust ]; then
  [ -f "$ROOT" ] || die "$ROOT is missing. Run 'make bootstrap' first."
  need_cmd openssl "Install OpenSSL."
  # SHA-1, as uppercase hex without colons: the form Windows and macOS show.
  THUMBPRINT=$(openssl x509 -in "$ROOT" -noout -fingerprint -sha1 | sed 's/.*=//' | tr -d ':' | tr 'a-f' 'A-F')
fi

# describe: say which certificate this is before anything asks you to confirm it.
describe() {
  info "Root certificate: $(openssl x509 -in "$ROOT" -noout -subject | sed 's/.*CN *= *//')"
  info "SHA-1 thumbprint: $(printf '%s\n' "$THUMBPRINT" | sed 's/\(........\)/\1 /g; s/ $//')"
}

# --- WSL2: Windows' CurrentUser\Root ---------------------------------------------------------------

PS_PRELUDE=$(
  cat <<'EOF'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
EOF
)

PS_CHECK=$(
  cat <<'EOF'
if (Test-Path "Cert:\CurrentUser\Root\$env:RSL_THUMBPRINT") { 'yes' } else { 'no' }
EOF
)

# Import-Certificate needs a file: write the bytes received through WSLENV to a temporary one, after
# checking they are the certificate whose thumbprint was shown.
PS_TRUST=$(
  cat <<'EOF'
$bytes = [Convert]::FromBase64String($env:RSL_ROOT_DER)
$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($bytes)
if ($cert.Thumbprint -ne $env:RSL_THUMBPRINT) { 'mismatch'; exit }
$file = Join-Path $env:TEMP ('rsl-commerce-root-' + [guid]::NewGuid() + '.cer')
[IO.File]::WriteAllBytes($file, $bytes)
$err = ''
try { Import-Certificate -FilePath $file -CertStoreLocation Cert:\CurrentUser\Root | Out-Null }
catch { $err = $_.Exception.Message }
finally { Remove-Item -LiteralPath $file }
if (Test-Path "Cert:\CurrentUser\Root\$env:RSL_THUMBPRINT") { 'added' } else { "declined $err" }
EOF
)

# Matches the organization exactly, so other roots (an mkcert root, for one) are never touched.
PS_UNTRUST=$(
  cat <<'EOF'
$pattern = '(^|, )O=' + [regex]::Escape($env:RSL_ROOT_O) + '(,|$)'
foreach ($c in @(Get-ChildItem Cert:\CurrentUser\Root | Where-Object { $_.Subject -match $pattern })) {
  try { Remove-Item -LiteralPath $c.PSPath } catch { }
  if (Test-Path -LiteralPath $c.PSPath) { 'kept ' + $c.Thumbprint } else { 'removed ' + $c.Thumbprint }
}
EOF
)

# powershell <script>: run a script in Windows PowerShell. It goes in encoded, so no shell quoting
# reaches it, and values go in as environment variables listed in WSLENV, never spliced into the code.
powershell() {
  ps_exe=$(wslpath -u 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe')
  [ -x "$ps_exe" ] || die "Windows PowerShell isn't at $ps_exe. Is WSL interop turned off?"
  RSL_THUMBPRINT=$THUMBPRINT RSL_ROOT_O=$RSL_ROOT_O RSL_ROOT_DER=$(sed '/-----/d' "$ROOT" 2>/dev/null | tr -d '\n') \
    WSLENV="${WSLENV:+$WSLENV:}RSL_THUMBPRINT:RSL_ROOT_O:RSL_ROOT_DER" \
    "$ps_exe" -NoProfile -EncodedCommand "$(printf '%s\n%s\n' "$PS_PRELUDE" "$1" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)" |
    tr -d '\r'
}

wsl_check() {
  [ "$(powershell "$PS_CHECK")" = yes ]
}

wsl_trust() {
  describe
  if wsl_check; then
    ok "Windows already trusts it (CurrentUser\\Root)."
    return 0
  fi
  info "Windows will ask you to confirm. Check that its thumbprint matches the one above, then choose Yes."
  result=$(powershell "$PS_TRUST")
  case $result in
    added) ok "Windows trusts it now (CurrentUser\\Root). Restart your browsers if they still warn." ;;
    declined*) die "Windows didn't add it (${result#declined }). Run 'make trust' again and choose Yes." ;;
    *) die "Windows PowerShell answered '$result'." ;;
  esac
}

wsl_untrust() {
  result=$(powershell "$PS_UNTRUST")
  [ -n "$result" ] || {
    ok "Windows has no rsl-commerce root to remove."
    return 0
  }
  printf '%s\n' "$result" | while read -r what tp; do
    if [ "$what" = removed ]; then ok "removed $tp from CurrentUser\\Root"; else warn "kept $tp (the dialog was declined)"; fi
  done
}

# --- macOS: the System keychain --------------------------------------------------------------------

KEYCHAIN=/Library/Keychains/System.keychain

# macos_ours: the SHA-1 of every certificate in the System keychain named like this platform's roots.
macos_ours() {
  security find-certificate -a -Z -c "$RSL_ROOT_CN" "$KEYCHAIN" 2>/dev/null | sed -n 's/^SHA-1 hash: //p'
}

macos_check() {
  macos_ours | grep -qx "$THUMBPRINT"
}

macos_trust() {
  describe
  if macos_check; then
    ok "The System keychain already trusts it."
    return 0
  fi
  info "sudo asks for your password to add it to the System keychain."
  sudo security add-trusted-cert -d -r trustRoot -k "$KEYCHAIN" "$ROOT"
  macos_check || die "the certificate isn't in the System keychain."
  ok "The System keychain trusts it now. Restart your browsers if they still warn."
}

macos_untrust() {
  for tp in $(macos_ours); do
    sudo security delete-certificate -Z "$tp" -t "$KEYCHAIN"
    ok "removed $tp from the System keychain"
  done
}

# --- Linux: the system store and NSS ---------------------------------------------------------------

# linux_anchor: where this distribution's system store takes an extra root, or nothing when unknown.
linux_anchor() {
  if [ -d /usr/local/share/ca-certificates ] && command -v update-ca-certificates >/dev/null 2>&1; then
    echo /usr/local/share/ca-certificates/rsl-commerce-dev-ca.crt
  elif [ -d /etc/pki/ca-trust/source/anchors ] && command -v update-ca-trust >/dev/null 2>&1; then
    echo /etc/pki/ca-trust/source/anchors/rsl-commerce-dev-ca.crt
  fi
}

linux_refresh() {
  if command -v update-ca-certificates >/dev/null 2>&1; then sudo update-ca-certificates; else sudo update-ca-trust; fi
}

# nss_dbs: Chrome's NSS database and each Firefox profile's (the snap's too), one per line.
nss_dbs() {
  for db in "$HOME/.pki/nssdb" "$HOME"/.mozilla/firefox/*/ "$HOME"/snap/firefox/common/.mozilla/firefox/*/; do
    if [ -f "${db%/}/cert9.db" ]; then printf '%s\n' "${db%/}"; fi
  done
}

linux_check() {
  anchor=$(linux_anchor)
  [ -n "$anchor" ] && cmp -s "$ROOT" "$anchor"
}

linux_trust() {
  describe
  anchor=$(linux_anchor)
  if [ -z "$anchor" ]; then
    warn "This distribution's system store is unknown here: add $ROOT to it by hand."
  elif cmp -s "$ROOT" "$anchor"; then
    ok "The system store already trusts it ($anchor)."
  else
    info "sudo asks for your password to add it to the system store."
    sudo cp "$ROOT" "$anchor"
    sudo chmod 644 "$anchor"
    linux_refresh
    ok "The system store trusts it now ($anchor)."
  fi
  if ! command -v certutil >/dev/null 2>&1; then
    warn "certutil isn't installed, so Chrome and Firefox don't trust it yet. Install libnss3-tools (Debian, Ubuntu) or nss-tools (Fedora), then run 'make trust' again."
    return 0
  fi
  nickname="$RSL_ROOT_CN $(printf '%s' "$THUMBPRINT" | cut -c1-8)"
  nss_dbs | while IFS= read -r db; do
    if certutil -L -d "sql:$db" -n "$nickname" >/dev/null 2>&1; then
      ok "already in $db"
    else
      certutil -A -d "sql:$db" -t C,, -n "$nickname" -i "$ROOT"
      ok "added to $db"
    fi
  done
}

linux_untrust() {
  anchor=$(linux_anchor)
  if [ -n "$anchor" ] && [ -f "$anchor" ]; then
    sudo rm -f "$anchor"
    linux_refresh
    ok "removed $anchor"
  fi
  command -v certutil >/dev/null 2>&1 || return 0
  nss_dbs | while IFS= read -r db; do
    certutil -L -d "sql:$db" | sed -n "s/^\\($RSL_ROOT_CN .*[^ ]\\)  *[A-Za-z]*,[A-Za-z]*,[A-Za-z]* *\$/\\1/p" |
      while IFS= read -r nickname; do
        certutil -D -d "sql:$db" -n "$nickname"
        ok "removed $nickname from $db"
      done
  done
}

case "$(platform_os)" in
  wsl) "wsl_$MODE" ;;
  macos) "macos_$MODE" ;;
  linux) "linux_$MODE" ;;
  *) die "unsupported system: trust $ROOT by hand." ;;
esac
