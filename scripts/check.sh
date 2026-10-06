#!/usr/bin/env bash
# The demo consumer's one entry point for its checks: the app's tests and the chart's renders, each
# with the planted defect it must catch. Run from anywhere inside the repository.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail() { echo "check: FAIL — $1" >&2; exit 1; }

npm test >/dev/null || fail "npm test"
echo "check: the app answers /healthz, and any other request 404"

render() {
  helm template demo deploy/chart -f "deploy/chart/values-$1.yaml" --set unitHost="demo.$1.example.test" \
    --set global.endpoints.registry.host=zot.example.test --set global.clusterIssuer=le --set global.env="$1" "${@:2}"
}
# One value out of the render on stdin: a yq expression over the documents of one kind and name.
pick() { yq -r "select(.kind == \"$1\" and .metadata.name == \"$2\") | ($3)" -; }

for stage in dev test; do
  out="$(render "$stage")" || fail "$stage render: $out"
  [ "$(pick Deployment hostyour-demo-consumer '.spec.template.spec.containers[0].image' <<<"$out")" = "zot.example.test/hostyour-demo-consumer:0.0.0-placeholder" ] \
    || fail "$stage render names no pinned image"
  [ "$(pick ServiceClaim registry-pull '.spec.service' <<<"$out")" = "registry" ] || fail "$stage claim registry-pull does not ask for registry"
  [ "$(yq -r 'select(.kind == "ServiceClaim") | .metadata.name' <<<"$out")" = "registry-pull" ] \
    || fail "$stage render claims a data service, so the unit cannot stand at the smallest size"
  [ "$(pick Deployment hostyour-demo-consumer '.spec.template.spec.securityContext | .runAsUser + ":" + .runAsGroup' <<<"$out")" = "1000:1000" ] \
    || fail "$stage pod names no numeric user and group, so the kubelet cannot verify it is not root"
  [ "$(pick Deployment hostyour-demo-consumer '.spec.template.spec.containers[0].readinessProbe.httpGet.path // ""' <<<"$out")" = "/healthz" ] \
    || fail "$stage readiness does not ask /healthz"
  echo "check: $stage renders the pinned image, the registry claim and no other, a numeric user"
done

for state in suspended quiesced; do
  out="$(render test --set "$state=true")" || fail "$state render: $out"
  [ "$(pick Deployment hostyour-demo-consumer '.spec.replicas' <<<"$out")" = "0" ] || fail "a $state unit still runs a pod"
  grep -q '^kind: Ingress' <<<"$out" && fail "a $state unit still has a public address"
  echo "check: a $state unit runs no pod and has no Ingress"
done

# The planted defect: a stage without its pin fails the render.
out="$(render test --set-json 'builds=[]' 2>&1)" && fail "a render without the image pin passed"
grep -qF 'the image pin is missing' <<<"$out" || fail "the render without the pin failed for another reason: $out"
echo "check: a render without the image pin fails, naming what is missing"

echo "check: OK — every check green"
