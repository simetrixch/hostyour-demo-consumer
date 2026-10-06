#!/usr/bin/env bash
# The demo consumer's one entry point for its checks: the probe's tests and the chart's renders, each
# with the planted defect it must catch. Run from anywhere inside the repository.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail() { echo "check: FAIL — $1" >&2; exit 1; }

[ -d node_modules ] || npm ci --no-audit --no-fund >/dev/null
npm test >/dev/null || fail "npm test"
echo "check: the probe writes and reads both stores, and a probe writing only Redis fails"

render() {
  helm template demo deploy/chart -f "deploy/chart/values-$1.yaml" --set unitHost="demo.$1.example.test" \
    --set global.endpoints.registry.host=zot.example.test --set global.clusterIssuer=le \
    --set-json 'mongodb.databases=["demo_probe"]' "${@:2}"
}
for stage in dev test; do
  out="$(render "$stage")" || fail "$stage render: $out"
  grep -q 'image: "zot.example.test/hostyour-demo-consumer:' <<<"$out" || fail "$stage render names no pinned image"
  grep -q 'key: REDIS_URI' <<<"$out" || fail "$stage render hands the app no REDIS_URI"
  grep -q 'key: DATABASE_URL' <<<"$out" || fail "$stage render hands the app no DATABASE_URL"
  [ "$(grep -c '^kind: ServiceClaim' <<<"$out")" -eq 3 ] || fail "$stage render does not claim redis, mariadb and registry-pull"
  echo "check: $stage renders the pinned image, both connection strings and three claims"
done

out="$(render test --set quiesced=true)" || fail "quiesced render: $out"
grep -q 'replicas: 0' <<<"$out" || fail "a quiesced unit still runs a pod"
grep -q '^kind: Ingress' <<<"$out" && fail "a quiesced unit still has a public address"
echo "check: a quiesced unit runs no pod and has no Ingress"

# The planted defects: a stage without its pin, and a MariaDB claim without databases, fail the render.
out="$(render test --set-json 'builds=[]' 2>&1)" && fail "a render without the image pin passed"
grep -qF 'the image pin is missing' <<<"$out" || fail "the render without the pin failed for another reason: $out"
out="$(render test --set-json 'mongodb.databases=null' 2>&1)" && fail "a MariaDB claim without databases rendered"
grep -qF 'mongodb.databases is delivered by the platform' <<<"$out" || fail "the render without databases failed for another reason: $out"
echo "check: a render without the image pin or without databases fails, naming what is missing"

echo "check: OK — every check green"
