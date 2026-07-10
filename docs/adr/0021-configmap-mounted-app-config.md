# ADR-0021: ConfigMap-mounted app config (`manifest_ref`/`packs_ref`)

- **Status:** Accepted
- **Date:** 2026-07-10
- **Builds on:** ADR-0020 (`secret_ref`/`envFrom` — the precedent this mirrors).

---

## Context

`ai-employees-core` is a second real workload, a chassis repo (not Casey — a durability/
platform-fit gate, D18 in its own design record) whose walking-skeleton role needs two files
delivered into the container that are **deliberately not baked into the image**: a role
manifest (`manifest.yaml`) and a custom capability pack (`echo.py`). Confirmed directly against
the actual Dockerfile and app code, not assumed: the image only contains `pyproject.toml`,
`uv.lock`, and `src/` — no manifest, no example packs — and the app's own loader
(`role_loader.py`) raises if `MANIFEST_PATH` isn't set. This is a real requirement of the
chassis's core premise ("a new AI Employee is a new manifest, never a new codebase") — behavior
changes shouldn't require an image rebuild.

`secret_ref`/`envFrom` (ADR-0020) doesn't fit: it delivers *values* as env vars, not *files*,
and manifest/pack content isn't a secret in the first place.

## Decision

**D21-1. Two specific fields, not a generic config-mount mechanism.** `manifest_ref` and
`packs_ref` (both optional, both unset by default) name k8s ConfigMaps a human/CI pre-creates,
mounted as volumes with fixed paths and env vars matching the app's exact contract:
`MANIFEST_PATH` (a single file — the `manifest_ref` ConfigMap must have a key literally named
`manifest.yaml`) and `PACKS_DIR` (a directory — each key in the `packs_ref` ConfigMap becomes
one file). Narrow on purpose: this is shaped for the concrete need in front of it, not a
speculative "mount arbitrary config" primitive. Generalize when a second, differently-shaped
need actually shows up.

**D21-2. Unlike `secret_ref`, these are opt-in per unit, not always-present-but-possibly-empty.**
A unit that doesn't declare `manifest_ref`/`packs_ref` gets no `MANIFEST_PATH`/`PACKS_DIR` env
vars at all — matching the app's own `str | None = None` default. `secret_ref` always renders
(optional Secret, fine to be empty); a manifest is not optional in the same way — an agent-unit
with no manifest declared shouldn't silently get an empty mount and a confusing runtime error.

**D21-3. `optional: true` on the ConfigMap volumes anyway** — for the same reason ADR-0020's
Secrets are optional: the platform shouldn't block pod scheduling on content it doesn't own.
If the ConfigMap is missing, kubelet mounts an empty directory; the app's own fail-closed
loader (`MANIFEST_PATH` set but the file absent) is what actually catches the problem, at the
correct layer (application config validation, not platform scheduling).

**D21-4. Explicitly NOT GitOps-tracked, and that's a known gap, not a design choice worth
defending.** These ConfigMaps are created directly against the cluster (same mechanism as
`git-creds`, ADR-0018's runbook), not rendered by `scripts/render-payload.rb` or committed
anywhere. Unlike Secrets, there's no confidentiality reason for this — manifest/pack content
is exactly the kind of thing that *should* be in git, reviewable, diffable. It isn't yet
because there's no cross-repo mechanism to pull that content from the workload repo into this
one at render time, and building one is out of scope for a gate test. **If `ai-employees-core`
becomes a recurring onboarding flow** (many roles, regularly updated) rather than a one-time
skeleton, this needs a real design: likely the workload repo packages manifest+packs as an OCI
artifact or commits them to a conventional path this repo's renderer reads, turning
`manifest_ref`/`packs_ref` into rendered, committed ConfigMap YAML instead of an ad-hoc
`kubectl create configmap`. Tracked, not forgotten — same discipline as every other deferred
decision in `docs/PLAN.md`.

## Consequences

- Zero schema impact on units that don't need this — `cs-agent-api`/`cs-agent-worker` and
  `search-a` are unaffected (confirmed: their rendered output only gained a doc-comment line).
- The `ai-employees-core` walking skeleton can now be delivered through the same registry path
  as every other unit, with the manifest/pack content swappable without a rebuild — matching
  the chassis's own design intent.
- A concrete follow-up is recorded (D21-4) rather than silently accepted as permanent.
