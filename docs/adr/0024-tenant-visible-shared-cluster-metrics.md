# ADR-0024: Tenant-visible shared-cluster metrics — self-hosted Grafana/Prometheus behind a label-enforcing proxy

- **Status:** Accepted
- **Date:** 2026-07-17
- **Builds on:** ADR-0023 (platform-system default-deny — load-bearing here, see D24-3),
  ADR-0016 (whose "no self-hosted Temporal in shared environments" this deliberately does NOT
  contradict — see D24-1), ADR-0012 (ownership boundary), ADR-0004 (no building ahead of a
  real consumer — bounds v1 scope, D24-2).
- **Origin:** the reference-platform review, round 2 (PLAN.md "Reference-platform review
  outcomes"). The mechanics are stolen nearly verbatim; two of the reference's mistakes are
  inverted into explicit decisions here (D24-3, D24-4).

---

## Context

Tenant-project telemetry (logs, alerts, dashboards in the tenant's own GCP project) is already
isolated by IAM — a project boundary, stronger than anything a proxy can enforce. But pod
metrics for workloads on the **shared runtime cluster** land in the runtime project, where
tenants have no access at all: a tenant today has zero visibility into their own pods' CPU,
memory, or restarts. The reference platform solves this with one shared metrics backend, a
label-enforcing query proxy, and one Grafana organization per tenant.

Adopting that means running monitoring in the shared plane — which demands squaring with
ADR-0016's Won't-now on self-hosted Temporal in any shared environment.

## Decision

**D24-1. Self-hosted monitoring in the shared plane is acceptable where self-hosted Temporal
is not, because monitoring's state is reconstructible from git; Temporal's state is
irreplaceable runtime data.** Concretely:
- *What it holds:* Temporal's database is the product — workflow histories are the
  conversations, generated at runtime, rebuildable from nothing. Prometheus holds samples that
  refill on the next 30s scrape; PromQL tolerates gaps by design.
- *Blast radius:* self-hosted Temporal failing breaks the platform's central promise
  (durability — the acceptance test itself). Prometheus failing blanks dashboards while
  workloads keep running; alerting does not ride on this stack (platform alerts: Cloud
  Monitoring at activation; tenant alerts: tenant projects).
- *Attack surface:* Temporal is a stateful multi-tenant listener every tenant workload must
  reach. The monitoring plane is out-of-band and (D24-3) unreachable from tenant pods.
- *The asymmetry of alternatives:* Temporal Cloud does the identical job at activation, so
  self-hosting it buys only ops risk. For metrics, the backend goes managed at activation
  (Managed Prometheus) but the tenant-facing layer — per-tenant Grafana orgs + label-enforced
  queries — has no managed GCP equivalent; it is the irreducible self-hosted remainder.
  (Grafana Cloud is the buy-option; per-tenant orgs there is a paid tier that loses at this
  scale — revisit if the fleet grows past ~10 tenants.)

**The rule with teeth: nothing precious may live on monitoring's disks.** Made literal —
Prometheus and Grafana both run on `emptyDir` (retention 24h). Orgs and datasources are
re-provisioned idempotently from the registry-stamped cluster state; dashboards, when they
arrive, ship as provisioned code. The moment someone proposes making Grafana's database the
home of something irreplaceable, it has crossed into Temporal's category and ADR-0016's
Won't-now applies to it.

**D24-2. Components and v1 scope** (`gitops/cluster/monitoring-*.yaml`, platform-system,
Config-Sync-owned like the Temporal dev server):
- **Prometheus** (single instance, 24h retention, `emptyDir`), scraping **kubelet cAdvisor
  only** (`/metrics/cadvisor` over the node port, authenticated by its own SA token +
  ClusterRole). cAdvisor gives per-container CPU/memory/network labeled by
  `namespace`/`pod` **without touching tenant pods** — so v1 needs no tenant-namespace
  ingress change at all. App-level `/metrics` scraping is deliberately NOT built: it needs a
  registry contract (opt-in annotation, port) and a tenant-namespace ingress rule, and no
  workload has asked (ADR-0004).
- **prom-label-proxy** `--label=namespace --enable-label-apis --error-on-replace`: injects
  `namespace=<tenant>` into every query/label/series request and refuses queries that try to
  override it. Series without a `namespace` label (machine-level) are automatically invisible
  through the proxy — the injected matcher can never match them.
- **Grafana** (`emptyDir`, sign-up/org-creation/anonymous off): one **organization per
  tenant**, each with a provisioned Prometheus datasource pointed at the proxy and pinned via
  `jsonData.customQueryParameters: "namespace=<tenant>"` (the supported mechanism for a
  per-datasource query param; the reference hand-built the same thing into the URL).

**D24-3. Reachability IS the tenant boundary — the reference's open hole, closed by
construction.** prom-label-proxy trusts the caller-supplied `namespace` parameter; whoever can
reach it can read any tenant's metrics. The reference's only guard is "ClusterIP, no ingress"
— every pod in their cluster can query every tenant. Here, ADR-0023 D23-3 already
default-denies platform-system both directions, and each monitoring component gets exactly its
dataflow, nothing more: Grafana→proxy:8080, proxy→Prometheus:9090,
Prometheus→{apiserver, kubelet:10250} (kind node ipBlock — activation replaces this scraper
wholesale, D24-5), plus DNS. **No ingress rule admits tenant namespaces to any monitoring
pod.** Humans reach Grafana by `kubectl port-forward` (kubelet path, not CNI-governed), same
as the Temporal UI.

**D24-4. Tenant users are never Grafana org Admin — enforced by test, not trust.** Org
membership isolates users; the pinned datasource isolates queries; both collapse if a tenant
can edit datasources, which is an org-Admin permission (OSS Grafana; the reference review
overstated Editor's powers, but the rule is the same). The verification battery must include
"datasource write as tenant-org user → 403". Org + datasource provisioning is an idempotent
script (`scripts/grafana/provision-orgs.sh`) driven by the live `tenant`-labeled namespaces —
the same signal the Gatekeeper constraints trust, stampable only by Terraform, so it cannot
drift from the registry. This mirrors the `create-namespaces.sh` precedent (ADR-0019): script
now, Terraform Grafana provider at activation (with `ignore_changes` on org membership — it
mutates outside Terraform; the ADR-0012 lesson). The script warns on orphan orgs (org whose
namespace is gone) rather than auto-deleting — offboarding integration is a tracked follow-on.

**D24-5. Activation mapping** (register rows, not built): the scrape/storage half swaps to
Managed Prometheus (this ADR's Prometheus Deployment and its node-ipBlock egress rule are
local-plane-only in practice); proxy + Grafana + orgs stay; org provisioning moves to the
Terraform Grafana provider; each org gains a second, per-tenant Google Cloud Monitoring
datasource authenticating as the tenant's own GSA against the tenant's own project (the IAM
analogue of the reference's per-tenant workspace datasource); human auth moves from
local admin/password to Google auth.

## Consequences

- Tenants get real visibility into their own pods on the shared cluster — the last
  first-class gap versus the reference platform's observability story — with isolation resting
  on identity + reachability, not trust.
- New platform-system components mean new scoped NetworkPolicy rules (the D23-3 doctrine
  exercised for the first time: three components, three exact dataflow rules, zero
  namespace-level trust).
- `grafana-admin` Secret is human-pre-created (the `git-creds`/`lana-secrets` pattern) —
  operational step in the runbook, never in the registry.
- Verified live on kind (evidence in `docs/VERIFICATION.md`): scrape working, label
  enforcement (including the override refusal), org isolation through Grafana, the
  viewer-403 rule, tenant pods blocked from all three monitoring services while Temporal
  stays reachable, and the pod-kill acceptance demo re-run green.
- Not built, tracked: app-level `/metrics` scraping (needs a consumer + registry contract);
  alert rules on these metrics (M4's channel work first); dashboards-as-code; offboard
  pruning of Grafana orgs.
