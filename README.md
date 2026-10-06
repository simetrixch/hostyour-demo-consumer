# hostyour-demo-consumer

A demo consumer of the hostyour platform: one pod with no data service. It is the slimmest unit the Manager onboards, so a stage's lifecycle (onboard, add a stage, offboard, restore) can be proven live at the smallest size, `xsmall`.

## Calling it

The consumer answers on its unit host, `demo.<stage apex>`, for example `demo.dev.digitacloud.app` on the DEV stage.

| request | what it does |
| :--- | :--- |
| `GET /healthz` | answers 200 with `{ "ok": true }` |

Every other request answers 404.

## Onboarding it

In the Manager: Consumers → Onboard a consumer, the repository URL of this repository, a stage the manifest declares (`dev` or `test`), any active cluster, size `xsmall`. The manifest is `deploy/platform.yaml`; it claims no data service, so gate G24 lets the unit stand at the smallest size.

## How it is built

- `src/app.js`: the requests.
- `src/server.js`: the process, on 8080.
- `deploy/chart`: the Deployment, its Service and Ingress, and the claim `registry-pull` for the image's pull credential.
- `Containerfile`: the image the platform's build plane builds from a release.

The release kit (`release/`) and the build webhook come from the platform when the consumer is onboarded.

## Checks

The checks need Node.js 22, Helm 3 and yq 4 (mikefarah).

```
bash scripts/check.sh
```

On Windows, `pwsh scripts/check.ps1` runs the same file. It runs the app's tests and renders the chart for every stage, each with the planted defect it must catch.
