# hostyour-demo-consumer

A demo consumer of the hostyour platform. It brings its own Redis and its own MariaDB, writes one Redis key and one MariaDB row, and reads them back. A backup and a restore of a consumer's data services can thus be proven live: write before, read after.

## Calling it

The consumer answers on its unit host, `demo.<stage apex>`, for example `demo.test.digitacloud.app` on the TEST stage.

| request | what it does |
| :--- | :--- |
| `PUT /probe` with a short text as the body (at most 200 characters) | writes the text as the Redis key `probe` and as row `id=1` of the MariaDB table `probe`, then answers what it reads back |
| `GET /probe` | answers `{ "redis": "<text>", "mariadb": "<text>" }`, with `null` for whatever is missing |
| `GET /healthz` | answers 200 once both data services answer |

```
curl -X PUT --data '2026-10-06 proof' https://demo.test.digitacloud.app/probe
curl https://demo.test.digitacloud.app/probe
```

## The live proof

1. Onboard the consumer at the stage from the Manager. The manifest is `deploy/platform.yaml`: an own Redis, MariaDB with the database `demo_probe`.
2. `PUT /probe` with a text that names the day.
3. Back the consumer up with the Manager's backup run.
4. Restore it into a fresh namespace with the Manager's restore run.
5. `GET /probe` there answers the same text for both stores.

## How it is built

- `src/probe.js`: the probe, written against two injected clients.
- `src/server.js`: the HTTP surface. It reads `REDIS_URI` and `DATABASE_URL` from the credential Secrets of its two ServiceClaims, which the platform's provisioner writes.
- `deploy/chart`: the Deployment, its Service and Ingress, and the claims `redis`, `mariadb` and `registry-pull`.
- `Containerfile`: the image the platform's build plane builds from a release.

The release kit (`release/`) and the build webhook come from the platform when the consumer is onboarded.

## Checks

```
bash scripts/check.sh
```

On Windows, `pwsh scripts/check.ps1` runs the same file. It runs the probe's tests and renders the chart for every stage, each with the planted defect it must catch.
