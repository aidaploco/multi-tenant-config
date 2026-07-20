# The deployment contract — platform ⇄ workload, one page

**Change rule (the reason this file exists): a PR touching this file is a JOINT decision with
the chassis repo (`ai-employees-core`), full stop — stated identically on both sides.**
Everything below is real and enforced, but was previously implicit across ADR-0016–0022/0027
and the chassis's own D-records; this page makes contract drift a diff. The chassis's
`DESIGN.md` carries a POINTER here (deliberately not a copy — two copies of a contract is how
contracts diverge); its `ChassisSettings` (`config.py`) is the code-side mirror of the env-var
half, and a change to either must land in both. Citation namespaces: `ADR-xxxx Dxx-x` =
platform decisions (this repo); bare `Dx`/`Mx` = chassis decisions (their `DESIGN.md`).

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
| `units.<name>.memory_scope_grants` | unset (**planned, not yet rendered** — see note below) | List of `"principal=scope"` strings → `MEMORY_SCOPE_GRANTS` env var | joint review 2026-07-20; chassis D24 |
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

**What does NOT ride here: authorization policy.** `MEMORY_SCOPE_GRANTS` (chassis D24 —
who may read whose memory) was proposed for the Secret ride and correctly rejected in joint
review (2026-07-20): a Secret is populated by a human running `kubectl` directly against the
cluster, no PR, no diff, no reviewer — exactly the unreviewed-authority shape ADR-0022 D22-3
named for ConfigMap packs before D22-2 gave manifests a reviewable, GitOps-tracked home. An
*authorization decision* needs the same treatment a *content* decision got. Home instead:
`units.<name>.memory_scope_grants` (top-level, **not** `overrides.*` — that bucket is
Terraform-consumed, ADR-0002's `iam_roles` being the only current member, `terraform/tenants/
modules/tenant/main.tf:229`; this needs the renderer's env-var path, the one `task_queue`/
`port`/`secret_ref` already use). Rendered as `MEMORY_SCOPE_GRANTS="principal=scope,…"`. Not
built: no tenant needs non-default entitlement yet (chassis D24(b)'s default requires zero
grants config), so this is ADR-0004 discipline as usual — build when a real tenant declares
it, not before. OIDC claims are the stated retirement path, same trajectory as
`HTTP_BEARER_TOKENS`.

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

**Confirmed against the live manifests (joint review 2026-07-20):** chassis D24's
`POST /v1/memory/search` needs no network change. It is a new route on the existing
`lana-api` container/Service (port 8000, already same-namespace-reachable) — no new Service,
no egress change, server-side only. **SB-2 is in-cluster-only** by design (chassis D24's
consumer, the per-user agent layer, doesn't exist yet); that consumer is the likely trigger
for the parked ingress/DNS ADR (`docs/PLAN.md`'s "gate: first external user of the chat
API") — tracked, not built, same discipline as everything else deferred here.

## What the platform never does

Never reads Secret contents, never sequences unit startup, never sees inside the image, never
runs evals (it demands their evidence), never renders for `restricted` tenants (ADR-0017
D17-5, ADR-0020, ADR-0026 D26-4).

---

# Chassis side (`ai-employees-core`) — verified against code as of their `f3f7183`

## Image & process shape

- One image, two agent-units sharing one task queue: API (default command, FastAPI) and
  worker (`command: ["python", "-m", "ai_employees_core.worker"]`) — chassis D18; platform
  ADR-0020 D20-1/D20-2.
- Nothing role-specific baked into the image; the role arrives at deploy time — D18, D20.

## Role mounts — the env var IS the contract, the path is the deployer's

The app reads `MANIFEST_PATH`/`PACKS_DIR` and never assumes a location (D7 fail-closed load,
D20 deploy-time trust tier). **On the platform** the values are `/etc/ai-employee/manifest/
manifest.yaml` and `/etc/ai-employee/packs` (ADR-0021 D21-1, read-only ConfigMap mounts); the
chassis's own docker-compose uses `/app/role/…` locally — a cosmetic difference precisely
*because* the paths ride the env vars. (Reconciled at merge time: the first would-be drift
this page caught.)

## Chassis env vars and their unset behavior (code mirror: `ChassisSettings`)

| Var | Unset behavior | Origin |
| --- | -------------- | ------ |
| `TEMPORAL_ADDRESS` / `TEMPORAL_NAMESPACE` / `TEMPORAL_TASK_QUEUE` | local-dev defaults; platform-injected in cluster | `ChassisSettings` since M1 (durable execution: D1/D6); platform: ADR-0019 D19-3 |
| `TEMPORAL_PAYLOAD_CODEC_KEY` | **worker refuses to start — no plaintext mode** | D9; platform: ADR-0016 D16-5, ADR-0020 D20-4 |
| `TEMPORAL_PAYLOAD_CODEC_KEY_ID` | `"default"` (rotation id) | D9 |
| `MANIFEST_PATH` / `PACKS_DIR` | API serves without `/v1/self`; worker needs the manifest | D7, D20; platform: ADR-0021 |
| `MODEL_TIER_LIGHT` / `MODEL_TIER_STANDARD` | defaulted | D7 (manifest names tiers; env maps them) |
| `MODEL_TIER_FRONTIER` | **no default — role build fails loud**, never a silent substitute | D7 |
| `OPENAI_API_KEY` (+ `ANTHROPIC_API_KEY` iff a tier/guardrail names `anthropic:*`) | provider SDK fails at call time; via `secret_ref` | D18; platform: ADR-0020 D20-3 |
| `PHOENIX_COLLECTOR_ENDPOINT` | tracing disabled; set = OTLP export; **never fail hard** | ADR-0027 D27-4; chassis D18 amendment 2026-07-19 |
| *(future)* `OTEL_EXPORTER_OTLP_HEADERS` | per-tenant ingest key via `secret_ref` — activation-time, nothing built | ADR-0027 amendment 2026-07-19; chassis D18 amendment |
| `POSTGRES_URL` | role runs memory-less | D8; platform: ADR-0028 |
| `EMBEDDING_MODEL` / `EMBEDDING_DIM` | defaulted (`text-embedding-3-small` / 1536) | D8 |
| `TENANT` | `"local"`; correlation label only — **isolation is the platform's job** | D16; platform: ADR-0013/0018 |
| `HTTP_BEARER_TOKENS` (`token:principal` CSV) | `/v1/tasks` + `/v1/approvals` refuse to serve; messages/self anonymous (dev posture) | D21 |
| `SLACK_WEBHOOK_URL` | Slack push sender disabled | D15 |
| `SLACK_SIGNING_SECRET` | unsigned webhooks accepted **with loud warning** (dev only) | D21 |
| `CONVERSATION_IDLE_SECONDS` | 3600 | D6a |

## Chassis naming conventions

- `employee.name`: `^[a-z][a-z0-9_]{2,40}$`, frozen per deployment — D7.
- Conversation workflow IDs: `conversation-<conversation_id>` — D6/D13.
- Task workflow IDs: `task-<task>-<uuid>` (HTTP-started), `task-<employee>-<task>`
  (schedule-started) — D6. Schedule IDs: `<employee>-<schedule-entry-name>` — M6.
- Trace `service.name` = Phoenix project = **`employee.name`, shared by the api and worker of
  one role** (deliberately per-role, not per-process — one conversation is one distributed
  trace) — D19; ADR-0027 correction `fe1244f`.
