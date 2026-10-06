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
    --set global.endpoints.registry.host=zot.example.test --set global.clusterIssuer=le --set global.env="$1" \
    --set global.endpoints.vault.url=https://vault.example.test --set global.vaultKvMount=secret --set global.vaultKubernetesAuthPath=kubernetes \
    --set-json 'mongodb.databases=["demo_probe"]' "${@:2}"
}
# One value out of the render on stdin: a yq expression over the documents of one kind and name.
pick() { yq -r "select(.kind == \"$1\" and .metadata.name == \"$2\") | ($3)" -; }

for stage in dev test; do
  out="$(render "$stage")" || fail "$stage render: $out"
  [ "$(pick Deployment hostyour-demo-consumer '.spec.template.spec.containers[0].image' <<<"$out")" = "zot.example.test/hostyour-demo-consumer:0.0.0-placeholder" ] \
    || fail "$stage render names no pinned image"
  for pair in REDIS_URI:hostyour-demo-consumer-redis DATABASE_URL:hostyour-demo-consumer-mariadb PROBE_TOKEN:hostyour-demo-consumer-app; do
    var=${pair%%:*}; secret=${pair##*:}
    got="$(pick Deployment hostyour-demo-consumer ".spec.template.spec.containers[0].env[] | select(.name == \"$var\") | .valueFrom.secretKeyRef | .name + \"/\" + .key" <<<"$out")"
    [ "$got" = "$secret/$var" ] || fail "$stage render takes $var from '$got', not $secret/$var"
  done
  for pair in redis:redis mariadb:mariadb registry-pull:registry; do
    claim=${pair%%:*}; service=${pair##*:}
    [ "$(pick ServiceClaim "$claim" '.spec.service' <<<"$out")" = "$service" ] || fail "$stage claim $claim does not ask for $service"
  done
  # The app reads each connection string from the Secret its claim names, so the two names must agree.
  for claim in redis mariadb; do
    [ "$(pick ServiceClaim "$claim" '.spec.secretName' <<<"$out")" = "hostyour-demo-consumer-$claim" ] \
      || fail "$stage claim $claim writes another Secret than the app reads"
  done
  # The token reaches the pod only when the ExternalSecret fills the Secret the pod reads, through the
  # store this chart creates, which logs in as the account this chart creates, bound to this stage.
  store="$(yq -r 'select(.kind == "SecretStore") | .metadata.name + " " + .spec.provider.vault.auth.kubernetes.serviceAccountRef.name' <<<"$out")"
  [ "$(pick ExternalSecret hostyour-demo-consumer-app '.spec.target.name + " " + .spec.secretStoreRef.name' <<<"$out")" = "hostyour-demo-consumer-app ${store%% *}" ] \
    || fail "$stage app Secret is filled into another Secret, or through a store the chart does not create"
  [ "$(pick ServiceAccount "${store##* }" '.metadata.annotations["vault.hashicorp.com/alias-metadata-stage"]' <<<"$out")" = "$stage" ] \
    || fail "$stage SecretStore logs in as an account the chart does not create, or one not bound to this stage"
  [ "$(pick ExternalSecret hostyour-demo-consumer-app '.spec.dataFrom[0].extract.key' <<<"$out")" = "$stage/consumer/hostyour-demo-consumer/app" ] \
    || fail "$stage app Secret is not read from this consumer's own Vault entry"
  [ "$(pick ServiceClaim redis '.spec | has("keyPatterns") or has("channelPatterns")' <<<"$out")" = "false" ] \
    || fail "$stage redis claim names patterns, which the CRD refuses empty and an own server does not use"
  [ "$(pick Deployment hostyour-demo-consumer '.spec.template.spec.securityContext | .runAsUser + ":" + .runAsGroup' <<<"$out")" = "1000:1000" ] \
    || fail "$stage pod names no numeric user and group, so the kubelet cannot verify it is not root"
  [ "$(pick Deployment hostyour-demo-consumer '.spec.template.spec.containers[0].readinessProbe.httpGet.path // ""' <<<"$out")" = "/healthz" ] \
    || fail "$stage readiness does not ask whether both data services answer"
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
out="$(render test --set-json 'mongodb.databases=null' 2>&1)" && fail "a MariaDB claim without databases rendered"
grep -qF 'mongodb.databases is delivered by the platform' <<<"$out" || fail "the render without databases failed for another reason: $out"
echo "check: a render without the image pin or without databases fails, naming what is missing"

echo "check: OK — every check green"
