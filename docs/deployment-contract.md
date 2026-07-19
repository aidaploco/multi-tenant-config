# The deployment contract — platform ⇄ workload, one page

**Change rule (the reason this file exists): a PR touching this file is a JOINT decision with
the chassis repo (`ai-employees-core`), full stop.** Everything below is real and enforced,
but was previously implicit across ADR-0016–0022/0027; this page makes contract drift a diff.
Mirror pointer lives in the chassis's `DESIGN.md`. Cite lines by their ADR/D-number — this
page introduces nothing new.

## Registry fields the workload's units may declare (`tenants/<slug>.yaml`)

| Field | Default | Meaning | Source |
| ----- | ------- | ------- | ------ |
| `units.<name>.type` | required | Only `agent-unit` renders today | ADR-0002 D2-4, ADR-0017 D17-5 |
| `units.<name>.version` | **required when opted in** | The deployed image tag; never `latest`. Prod changes need an eval report | ADR-0017 D17-5, ADR-0026 D26-4 |
| `units.<name>.opt_in` | `true` | Opted-out units render nothing | ADR-0017 D17-5 |
| `units.<name>.image` | unit name | Image repo when it differs from the unit name | ADR-0017 D17-5 |
| `units.<name>.task_queue` | unit name | Temporal task queue; API + worker units share one by declaring the same value | ADR-0016 D16-3, ADR-0019 D19-3 |
| `units.<name>.port` | `8080` | Container listen port (only meaningful with `expose_port`) | ADR-0020 D20-2 |
| `units.<name>.expose_port` | `true` | `false` = headless: no containerPort, **no Service** | ADR-0020 D20-2 |
| `units.<name>.command` | image CMD | Non-empty string array; one image, many roles | ADR-0020 D20-1 |
| `units.<name>.secret_ref` | unit name | Name of a **human-pre-created** k8s Secret (never in git) | ADR-0020 D20-3 |
| `units.<name>.manifest_ref` / `packs_ref` | unset | ConfigMaps rendered from `config/<tenant>/<ref>/` | ADR-0021 D21-1, ADR-0022 D22-2 |
| `units.<name>.overrides.iam_roles` | `[]` | Least-privilege GCP grants for the unit's identity | ADR-0002 D2-4 |
| `offboarding` (tenant-level) | absent | `true` renders the tenant EMPTY (payload prune) + freezes CI matrices | ADR-0026 D26-1 |
| `data_classification: restricted` | — | **Refused** by the renderer: no shared-plane delivery | ADR-0017 D17-5 (ADR-0001 D14) |

Environment merge: `environments.<env>.units` **shallow-merges over** `defaults.units` per
unit name — override = restate the whole unit (ADR-0002 D2-2).

## Env vars the platform sets on every agent-unit container

| Var | Value (local plane) | At activation | Source |
| --- | ------------------- | ------------- | ------ |
| `TEMPORAL_ADDRESS` | `temporal-frontend.platform-system.svc.cluster.local:7233` | Temporal Cloud endpoint, same var | ADR-0019 D19-3 |
| `TEMPORAL_NAMESPACE` | `<slug>-<env>` | same convention | ADR-0016 D16-3, ADR-0019 D19-2 |
| `TEMPORAL_TASK_QUEUE` | the unit's `task_queue` | same | ADR-0019 D19-3 |
| `PHOENIX_COLLECTOR_ENDPOINT` | `http://phoenix-<slug>.platform-system.svc.cluster.local:6006/v1/traces` | same var; per-tenant API key joins via the Secret | ADR-0027 D27-4 |
| `MANIFEST_PATH` | `/etc/ai-employee/manifest/manifest.yaml` — only when `manifest_ref` set | same | ADR-0021 D21-1 |
| `PACKS_DIR` | `/etc/ai-employee/packs` — only when `packs_ref` set | same | ADR-0021 D21-1 |

**App obligations:** treat `PHOENIX_COLLECTOR_ENDPOINT` as optional (fail-soft, no endpoint =
tracing off; ADR-0027 D27-4); a worker that cannot load its payload codec **fails closed**
(ADR-0016 D16-5).

## The Secret ride (`envFrom`, always optional)

Every container gets `envFrom: secretRef {name: <secret_ref>, optional: true}` — a missing
Secret never blocks scheduling (ADR-0020 D20-3). Keys are app-owned values the platform never
reads; established conventions riding it: `TEMPORAL_PAYLOAD_CODEC_KEY` (32 raw bytes;
ADR-0020 D20-4), `HTTP_BEARER_TOKENS` (`token:principal` pairs; chassis D21), app secrets
(`OPENAI_API_KEY`, `POSTGRES_URL`, …). At activation: same ride, sourced via the Secrets
Store CSI driver (ADR-0020 D20-5); per-tenant Phoenix API key joins here (ADR-0027 amendment
2026-07-19).

## Naming + placement conventions (enforced, not advisory)

| Thing | Convention | Enforced by | Source |
| ----- | ---------- | ----------- | ------ |
| Namespace | `<slug>` (one per tenant per cluster) | Terraform-only creation | ADR-0013 D13-3 |
| Pod identity | KSA named **exactly** the unit name | exact-KSA Gatekeeper constraint, fail-closed (+ deny-default-sa) | ADR-0018 D18-3, ADR-0015 |
| Image ref | `<registry-host>/<image>:<version>`; host `localhost:5001` locally, Artifact Registry at activation | renderer constant | ADR-0017 D17-4 |
| Payload file | `gitops/payload/<env>/<slug>/<unit>.yaml`, generated, never hand-edited | CI re-render drift check | ADR-0017 D17-1 |
| Env scoping | `configsync.gke.io/cluster-name-selector: runtime-<env>` on every object | Config Sync cluster name = `runtime-<env>` | ADR-0017 D17-3, ADR-0018 D18-2 |
| Service | unit name, `port == targetPort == units.<name>.port`; headless units have none | renderer | ADR-0017/0020 |
| ConfigMaps | named by the `*_ref` value (shared across units), one key per file; `manifest_ref` must contain key `manifest.yaml` | renderer dies if content missing | ADR-0021 D21-1, ADR-0022 D22-2 |
| Resources | requests `100m/128Mi`, limits `500m/512Mi`, replicas 1 | rendered; not per-unit-tunable yet | ADR-0017 D17-5 |
| Labels | `app=<unit>`, `tenant=<slug>`, `environment=<env>` | rendered; `tenant` namespace label is Terraform-stamped and load-bearing | ADR-0018, ADR-0027 D27-2 |

## What the workload can reach (the network half of the contract)

Egress from a tenant namespace is **default-deny plus exactly**: DNS, same-namespace,
`platform-system` (which admits only Temporal `7233` and the tenant's own Phoenix `6006` at
the pod+port level), and external internet **minus private ranges**; `extra_egress_cidrs` is
a kind-mode-only escape hatch (ADR-0022 D22-4, ADR-0023 D23-3, ADR-0027 D27-2). Ingress:
default-deny + same-namespace (ADR-0013). Anything not listed here is not reachable, and
that's a feature.

## What the platform never does

Never reads Secret contents, never sequences unit startup, never sees inside the image, never
runs evals (it demands their evidence), never renders for `restricted` tenants (ADR-0017
D17-5, ADR-0020, ADR-0026 D26-4).
