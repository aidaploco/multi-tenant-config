# ADR-0020: Workload delivery shape for the first real agent — command overrides, headless units, app secrets

- **Status:** Accepted
- **Date:** 2026-07-08
- **Builds on:** ADR-0017 (the renderer), ADR-0019 (Temporal dev server + payload env wiring).
- **Amends:** ADR-0017 D17-5's manifest shape — adds fields, does not change the ownership or
  prune-and-rewrite decisions there.

---

## Context

`customer-service-agent` is the first real consumer of the delivery path, and its actual shape
— gathered directly from its own repo and a coordinating Claude Code session working there —
doesn't fit ADR-0017's original assumption of "one unit, one HTTP container, port 8080, no
extra config":

- **One image, two roles.** `cs-agent-backend:0.2.0` runs either as the HTTP API
  (`uvicorn api.app:app`, the image's own `CMD`) or as a Temporal worker
  (`python -m durable.worker`) depending on the command it's started with. Two units, same
  image, different `command`.
- **The worker has no HTTP surface at all.** No port to expose, no Service to render.
- **The API and worker must poll the same Temporal task queue** — the API enqueues work, the
  worker executes it. `task_queue` (ADR-0019) already supports this: set the same value on
  both units.
- **Real application config**, some of it genuinely secret: `OPENAI_API_KEY`, `POSTGRES_URL`
  (embeds a credential), `REDIS_URL`. None of this can go in the registry — the registry is a
  git-committed, public-facing file (`docs/adr/0004`'s whole point is that it's the single
  source of truth, reviewable in a PR; secrets and PRs don't mix).
- **The real port is 8000** (confirmed from the Dockerfile directly), not the 8080 the renderer
  hardcoded — a reminder to make it a registry field rather than special-case one more app.

## Decisions

**D20-1. `command` (optional array).** Overrides the image's own entrypoint/CMD. Validated:
non-empty array of strings, or the render fails fast. This is what lets one image serve two
units without two images, two Dockerfiles, or two repos.

**D20-2. `expose_port` (optional bool, default `true`) + `port` (optional int, default
`8080`).** `port` replaces the old hardcoded `8080` — real apps listen where they listen.
`expose_port: false` renders **no** `containerPort` and **no Service at all** for that unit
("headless"). A worker with no inbound traffic gets no dangling Service pointing at nothing.

**D20-3. `secret_ref` (optional string, default: the unit name) + an always-present, always-
optional `envFrom`.** Every rendered container gets:
```yaml
envFrom:
  - secretRef: { name: <secret_ref>, optional: true }
```
`optional: true` is load-bearing, not a nicety: it means the renderer never needs to know
*whether* a Secret exists, only *what it's called* — a unit with no real secrets needs (like
`search-a`, still a placeholder) simply has no matching Secret and starts fine with an empty
env contribution. The Secret itself is **never** in this repo, never in the registry, never
rendered — a human creates it directly against the cluster, the same pattern already
established for Config Sync's own `git-creds` (ADR-0018's runbook). `cs-agent-api` and
`cs-agent-worker` share one Secret (`secret_ref: cs-agent-secrets` on both) since they need
identical application config.

**D20-4. The D16-5 codec key rides in the same Secret, once a real worker asked for a concrete
shape.** ADR-0019 deliberately did not wire this — guessing Secret-vs-ConfigMap-vs-mount-path
risked doing it twice. The answer came back concrete: `TEMPORAL_PAYLOAD_CODEC_KEY` as a plain
env var, because it slots directly into the app's existing `pydantic-settings` config with no
mount handling. It is added as one more key in `cs-agent-secrets`, delivered by the same
`envFrom` — no separate mechanism.

**D20-5. Local secret delivery is a plain k8s Secret; the activation-checklist entry now names
its real successor explicitly.** A CSI-driver-backed vault (Secrets Store CSI Driver +
`secrets-store-csi-driver-provider-gcp`, the direct GCP analogue of an Azure Key Vault CSI
setup) is the right tool for a real cluster — but there is no GCP org here to back it with, so
it would have nothing to mount. Consistent with this project's whole mock-first shape (ADR-0012
D12-4's identical local-token-vs-Secret-Manager tradeoff): plain Secret now, name the cloud
successor on the activation checklist rather than build toward a vault that can't exist yet.
`docs/PLAN.md`'s activation checklist line is updated from "Secret Manager module" to name the
CSI driver explicitly.

## What stays application-side

Everything about *what* the API and worker do with their env vars and secrets — the platform
delivers named values, it does not know or care what `OPENAI_API_KEY` is used for. Knowledge
ingestion ordering (the worker assumes the API has initialized shared state first) is an
application concern; the platform renders both units, it does not sequence their startup.

## Consequences

- The registry schema has grown by four optional unit fields in two ADRs now (`task_queue`,
  then `command`/`port`/`expose_port`/`secret_ref`) — every one of them optional with a sane
  default, so `search-a`'s original minimal declaration still renders unchanged. Schema growth
  driven by a real consumer, not speculatively, is exactly ADR-0004's intended shape for this
  layer.
- A tenant can now deliver an arbitrarily-shaped multi-unit application (API + worker + future
  roles) from one image without any renderer change — only registry data.
- `docs/VERIFICATION.md` gains a live-verification row once `cs-agent-api`/`cs-agent-worker`
  are actually deployed and reachable.
