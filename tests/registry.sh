#!/usr/bin/env bash
# The package workflow end to end, with resid-serial and resid-json as the
# packages: a registry that takes signed uploads, both packages uploaded to
# it, and an app that names only `resid-json = 0.1.0` and gets
# resid-serial too (resid-json's own `path` is not there in a published
# copy, so its `version` comes from the registry).
#
#   tests/registry.sh
#
# Uses resid-pkg, resid-manifest and residc from PATH or ~/.resid/bin.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERIAL="${SERIAL:-$ROOT/../resid-serial}"
bin() { command -v "$1" || echo "$HOME/.resid/bin/$1"; }
PKG="$(bin resid-pkg)"; MAN="$(bin resid-manifest)"; RESIDC="$(bin residc)"
W="$(mktemp -d)"
SRV=""
trap '[ -n "$SRV" ] && kill "$SRV" 2>/dev/null; rm -rf "$W"' EXIT
fail() { echo "FAIL registry: $*"; exit 1; }

# The publisher's key (in the registry's keyring) and the registry's own.
"$PKG" keygen "$W/alice.key" "$W/alice.pub" > /dev/null
"$PKG" keygen "$W/index.key" "$W/index.pub" > /dev/null
mkdir -p "$W/keyring" "$W/registry"
cp "$W/alice.pub" "$W/keyring/alice.pub"

"$PKG" serve "$W/registry" --port 0 --port-file "$W/port" --upload "$W/keyring" --index-key "$W/index.key" > "$W/serve.log" 2>&1 &
SRV=$!
for _ in $(seq 1 100); do [ -s "$W/port" ] && break; sleep 0.1; done
[ -s "$W/port" ] || fail "the registry did not start: $(cat "$W/serve.log")"
URL="http://127.0.0.1:$(cat "$W/port")"

"$PKG" upload "$SERIAL" "$URL" "$W/alice.key" || fail "upload resid-serial"
"$PKG" upload "$ROOT" "$URL" "$W/alice.key" || fail "upload resid-json"

mkdir -p "$W/app/src"
cat > "$W/app/resid.toml" <<TOML
[package]
name = "app"
version = "0.1.0"
root = "src/main.resid"

[registry]
url = "$URL"
pubkey = "$(cat "$W/index.pub")"

[dependencies.resid-json]
version = "0.1.0"
TOML
cat > "$W/app/src/main.resid" <<'RESID'
import "resid-json/json.resid";

Int main() {
    List(Int) xs = [1, 2, 3];
    Str text = match to_json(xs) { Ok(t) => t, Err(e) => "error" };
    println(text);
    return 0;
}
RESID
"$MAN" build "$W/app/resid.toml" "$RESIDC" > "$W/build.log" 2>&1 || fail "build: $(grep -v '^OK ' "$W/build.log" | tail -5)"
got="$("$W/app/target/resid/app")"
[ "$got" = "[1,2,3]" ] || fail "the app printed '$got'"
grep -q "resid-serial 0.1.0" "$W/app/resid.lock" || fail "resid.lock does not pin resid-serial: $(cat "$W/app/resid.lock")"
echo "PASS registry (resid-serial and resid-json uploaded, an app built from them)"
