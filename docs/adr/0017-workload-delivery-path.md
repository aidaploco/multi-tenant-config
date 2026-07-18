# ADR-0017: Workload delivery path — a registry renderer stamps the app payload into the synced tree

- **Status:** Accepted
- **Date:** 2026-07-06
- **Builds on:** ADR-0002 (units, axis 2), ADR-0012 (Config Sync, D12-3 ownership), ADR-0016
  (Temporal workers are ordinary agent-unit pods — this is the path that deploys them).
- **Amends:** ADR-0004 (invokes its documented generator graduation, surgically) and ADR-0012
  D12-3 (the ownership table gains the per-tenant app-payload row for real).

---

## Context

The registry declares units (`search-a: { type: agent-unit, version: 1.4.0 }`) and the platform
provisions their *identity* (WI service account, KSA binding) — but **nothing delivers a
workload**. `units.*.version` is recorded and means nothing. M3's acceptance test needs the
agent's worker pods to arrive in the tenant's namespace *through a governed path*, not via
`kubectl apply` from a laptop.

The delivery target is the Config-Sync-synced `gitops/` tree: ADR-0012 D12-3 already reserved
per-tenant **app payload** (Deployments/Services/ConfigMaps) as Config Sync's turf, and the
ownership guard (`scripts/check-gitops-ownership.rb`) already polices the boundary. What's
missing is how payload manifests *get into* that tree from the registry.

### Options

| Option | Why not |
| ------ | ------- |
| Helm releases per unit (CI runs `helm upgrade`) | Imperative push from CI to cluster — bypasses the reconciliation loop ADR-0012 chose; cluster state no longer equals git. |
| A Kubernetes operator watching the registry | A platform service to build, run, and secure — for two tenants. Wrong side of ADR-0001 D3. |
| Per-tenant `RepoSync` pointing at workload repos | Hands tenants a direct write path to the shared cluster; the platform loses review of what lands. Already a Won't-now in the plan. |
| Hand-written manifests in `gitops/` | Duplicates the registry by hand — ADR-0004's rejected Option 3, and the exact dual-source failure mode the registry exists to prevent. |
| **A renderer: registry → committed manifests** | **Chosen — below.** |

## Decisions

**D17-1. The renderer is ADR-0004's generator graduation, invoked surgically.** A small script
(`scripts/render-payload.rb`) is a pure function *registry → Kubernetes app-payload manifests*,
stamped into `gitops/payload/` as **reviewable committed diffs**. This adopts the generator
pattern ADR-0004 pre-committed to — with its scope discipline:

- **Only the slice that fans out is generated** — the k8s app payload. The Terraform side stays
  fully data-driven (`for_each` over the registry); ADR-0004's graduation triggers for
  *Terraform* generation remain unfired and unchanged.
- **The generated-vs-custom split is hard** (the reference platform's mitigation, adopted from
  day one): everything under `gitops/payload/` is generated, carries a `GENERATED — do not
  edit` header, and is **never hand-edited**. There is no custom carve-out inside the payload
  tree — per-unit configuration goes in the registry, or it doesn't exist.
- CI enforces the discipline: a re-render check fails any PR whose committed payload doesn't
  match what the registry renders (so a registry edit without a re-render, or a hand edit of a
  generated file, cannot merge).

**D17-2. Ownership amendment (ADR-0012 D12-3).** Config Sync now concretely owns
`gitops/payload/` — **workload kinds only** (Deployments/Services/ConfigMaps). Terraform keeps
every policy kind (Namespace, NetworkPolicy, quota, RBAC, ServiceAccounts) exactly as before;
`scripts/check-gitops-ownership.rb` continues to gate the boundary. Exactly one controller per
object, still.

> **Amended by ADR-0027 (D27-5).** A second rendered tree, `gitops/platform/`, carries
> platform-plane infra (per-tenant Phoenix), where NetworkPolicy/ServiceAccount ARE admitted —
> but only namespaced to `platform-system`, which Terraform never manages. The tenant-namespace
> policy-kind rule above is unchanged. The manifest *shape* in D17-5 was also extended by
> ADR-0020 (command/port/expose_port/secret_ref — headless units render no Service), ADR-0021
> (manifest_ref/packs_ref), and ADR-0027 (the `PHOENIX_COLLECTOR_ENDPOINT` env var).

**D17-3. Per-environment scoping via Config Sync cluster-name selectors.** Every runtime
cluster syncs the *same* `gitops/` tree (one source of truth, no per-cluster duplication);
payload objects carry `configsync.gke.io/cluster-name-selector: runtime-<env>` so the dev
cluster applies only dev payload. The contract: **a runtime cluster's Config Sync cluster name
is `runtime-<env>`** — wired for kind/OSS in M2 (where it is locally verifiable) and a
verification-register row for the GKE/Fleet path. Fallback if selectors prove unworkable on
either path: split `policy_dir` per environment and render the cluster baseline into each
env tree (more duplication, same renderer).

**D17-4. Image trust chain — designed now, deferred to activation.** The workload repo (e.g.
`customer-service-agent`) builds and pushes its image; the platform delivers it by digest-less
tag pinned in the registry (`units.*.version`). At activation this means: an **Artifact
Registry** module, and a **second WIF provider** scoped to the workload repos with push-only
rights to their own repository path — recorded here, on the activation checklist, **not built**
(no cloud to verify it against). Locally, the kind **local-registry** pattern
(`localhost:5001`) stands in; the registry host is a constant in the renderer, flipped and
re-rendered at activation.

**D17-5. What renders, concretely.**
- Only `agent-unit`s with `opt_in: true` render today (the only built archetype); `app-unit`
  joins when it exists.
- Per (tenant, unit, environment): one file `gitops/payload/<env>/<tenant>/<unit>.yaml` holding
  a Deployment + Service into the tenant's namespace.
- `image = <registry-host>/<units.*.image | unit name>:<units.*.version>` — **`version` is now
  required** for an opted-in agent-unit; the renderer refuses to render without it (never
  `latest`; registry honesty).
- `serviceAccountName` = the unit's KSA (the same name `agent-identity` binds for Workload
  Identity) — which is exactly what M2's exact-KSA Gatekeeper constraint will pin.
- **Restricted tenants are refused**: `gitops/payload/` targets the *shared* runtime plane, and
  ADR-0001 D14 says regulated tenants never share it. A `restricted` tenant declaring an
  opted-in agent-unit fails the render until a dedicated delivery path exists.
- Rendering is a full re-stamp: the payload tree is pruned and rewritten every run, so **removing a
  unit or tenant from the registry removes its payload** — Config Sync prunes it from the
  cluster, *before* Terraform ever destroys the namespace (the offboard ordering the demo and
  M4's pipeline rely on).

## What stays application-side

The image's *contents* (workflow code, SDK config, the D16-5 codec implementation), health
endpoints, and the app's own config files. The platform renders where the workload runs, as
whom, and at which release — it never sees inside the image.

## Consequences

- `units.*.version` finally means something: it is the deployed image tag, per environment —
  dev genuinely runs ahead of prod, visibly, in a committed diff.
- Promotion is a registry PR (bump prod's `version`), which is precisely the hook M4's
  eval-gate needs — the gate reads the diff, no new mechanism.
- Two new registry semantics enforced by the renderer: agent-unit `version` required when
  opted in; restricted tenants can't target the shared plane.
- The payload tree is the first *generated* artifact in the repo — the re-render CI check is
  what keeps the registry the single source of truth.
- Live reconciliation of the payload (apply, prune, selector scoping) is verified on kind in
  M2; the Fleet-path cluster-name seam goes on the verification register now.
- **Why not Helm** (asked 2026-07-18; recorded here because the renderer is where the question
  lands). Helm offers three things — templating, packaging, and release/rollback machinery —
  and each is either already provided better or actively unwanted here. *Templating:* the
  renderer is that layer, with a property charts don't give: the rendered output IS the
  committed, reviewed, CI-drift-checked artifact (D17-1). Reviewing a chart + values file
  means mentally executing the template; reviewing this repo means reading the YAML that will
  hit the cluster. *Release machinery:* redundant under GitOps — git is the release history
  and `git revert` is rollback — and worse than redundant: Helm's release state would be a
  second owner of live objects, the ADR-0012 dual-ownership problem reintroduced on purpose.
  *Packaging:* for external consumers who install software with knobs; tenants install
  nothing — the registry is the interface. Helm IS the right tool when **consuming
  third-party software distributed as charts** (a kube-prometheus-stack, a self-hosted
  Temporal — both currently Won't-now; today's third-party pieces are single-Deployment
  manifests below the threshold where a chart pays for itself). If that day comes, the
  pattern that preserves D17-1 is `helm template` at authoring time — pinned chart version,
  output rendered to git, Config Sync applies: Helm as a manifest generator, never as a
  runtime release manager.
