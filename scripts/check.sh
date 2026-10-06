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
# One value out of the render on stdin: a yq expression over the documents of one kind and name.
pick() { yq -r "select(.kind == \"$1\" and .metadata.name == \"$2\") | ($3)" -; }

for stage in dev test; do
  out="$(render "$stage")" || fail "$stage render: $out"
  [ "$(pick Deployment hostyour-demo-consumer '.spec.template.spec.containers[0].image' <<<"$out")" = "zot.example.test/hostyour-demo-consumer:0.0.0-placeholder" ] \
    || fail "$stage render names no pinned image"
  for pair in REDIS_URI:hostyour-demo-consumer-redis DATABASE_URL:hostyour-demo-consumer-mariadb; do
    var=${pair%%:*}; secret=${pair##*:}
    got="$(pick Deployment hostyour-demo-consumer ".spec.template.spec.containers[0].env[] | select(.name == \"$var\") | .valueFrom.secretKeyRef | .name + \"/\" + .key" <<<"$out")"
    [ "$got" = "$secret/$var" ] || fail "$stage render takes $var from '$got', not $secret/$var"
  done
  for pair in redis:redis mariadb:mariadb registry-pull:registry; do
    claim=${pair%%:*}; service=${pair##*:}
    [ "$(pick ServiceClaim "$claim" '.spec.service' <<<"$out")" = "$service" ] || fail "$stage claim $claim does not ask for $service"
  done
  [ "$(pick ServiceClaim redis '.spec | has("keyPatterns") or has("channelPatterns")' <<<"$out")" = "false" ] \
    || fail "$stage redis claim names patterns, which the CRD refuses empty and an own server does not use"
  [ "$(pick Deployment hostyour-demo-consumer '.spec.template.spec.securityContext.runAsUser' <<<"$out")" = "1000" ] \
    || fail "$stage pod names no numeric user, so the kubelet cannot verify it is not root"
  [ "$(pick Deployment hostyour-demo-consumer '.spec.template.spec.containers[0].livenessProbe.httpGet.path // ""' <<<"$out")" != "/healthz" ] \
    || fail "$stage liveness pings the data services, so their outage restarts the pod"
  echo "check: $stage renders the pinned image, both connection strings from their own Secrets, three claims for their services, a numeric user"
done

for state in suspended quiesced; do
  out="$(render test --set "$state=true")" || fail "$state render: $out"
  [ "$(pick Deployment hostyour-demo-consumer '.spec.replicas' <<<"$out")" = "0" ] || fail "a $state unit still runs a pod"
  grep -q '^kind: Ingress' <<<"$out" && fail "a $state unit still has a public address"
  echo "check: a $state unit runs no pod and has no Ingress"
done

# The planted defects: a stage without its pin, and a MariaDB claim without databases, fail the render.
out="$(render test --set-json 'builds=[]' 2>&1)" && fail "a render without the image pin passed"
grep -qF 'the image pin is missing' <<<"$out" || fail "the render without the pin failed for another reason: $out"
for empty in null '[]'; do
  out="$(render test --set-json "mongodb.databases=$empty" 2>&1)" && fail "a MariaDB claim with databases $empty rendered"
  grep -qF 'mongodb.databases is delivered by the platform' <<<"$out" || fail "the render with databases $empty failed for another reason: $out"
done
echo "check: a render without the image pin or with no database fails, naming what is missing"

echo "check: OK — every check green"
