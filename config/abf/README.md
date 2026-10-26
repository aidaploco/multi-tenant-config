# config/abf/ — role manifests + packs, GitOps-tracked (ADR-0022 D22-2)

Content for `manifest_ref`/`packs_ref` ConfigMaps (ADR-0021), rendered by
`scripts/render-payload.rb` into `gitops/payload/` — reviewable, committed, pruned on removal
the same as every other generated artifact. Not automated: a human copies the file over from
the workload repo, same "don't build ahead of scale" discipline as everything else here
(ADR-0004). If this becomes a recurring, frequent sync, that's the trigger to automate it —
not before.

**Deliberately outside `gitops/`** (a real bug caught live, not a design given): Config Sync's
`RootSync` recursively scans everything under `dir: gitops` and tries to parse each `.yaml` as
a Kubernetes object. A role manifest has no `apiVersion`/`kind` — Config Sync rejected it
(`KNV2001: Object 'Kind' is missing`) the first time this lived at `gitops/config/`. `config/`
is a **source** directory the renderer reads, exactly like `tenants/` — never synced directly;
only its rendered *output* (a real ConfigMap, under `gitops/payload/`) is.

**Directory = the ref name** the registry's `manifest_ref`/`packs_ref` points at, not the unit
name — two units sharing one ref (the normal case: an API and a worker loading the same role)
render one ConfigMap, not two.

| Directory | Source | Synced at | Notes |
| --- | --- | --- | --- |
| `lana-manifest/` | `agent-chassis` `examples/lana/manifest.yaml` | `1476aef` | Lana's role manifest — guardrail thresholds, routing, escalation policy live here. |
| `lana-packs/packs/` | `agent-chassis` `examples/lana/packs/{billing,support}.py` | `1476aef` | Only the tenant-custom tier (ADR-0022 D20) — `message_length`/`prompt_injection`/`off_topic` guardrails moved to the curated, image-baked tier and are **not** here. |

To update: copy the new file(s) over, update the "Synced at" commit above, re-render
(`ruby scripts/render-payload.rb`), commit both together.
