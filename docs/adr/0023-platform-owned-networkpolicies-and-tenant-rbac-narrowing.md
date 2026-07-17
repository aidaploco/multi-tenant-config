# ADR-0023: NetworkPolicies are platform-owned — tenant RBAC narrowed to view + operate, enforced at two layers

- **Status:** Accepted
- **Date:** 2026-07-17
- **Builds on:** ADR-0013 (per-tenant namespaces; amends its RBAC detail), ADR-0022 D22-4
  (default-deny egress baseline — the thing this ADR makes tamper-proof), ADR-0018 (exact-KSA /
  fail-closed admission posture), ADR-0012 (Terraform/GitOps ownership boundary).
- **Origin:** a structured review of a mature external reference platform (multi-tenant
  Kubernetes on another cloud; architecture shared, no code). Its strongest pattern — the same
  isolation intent enforced at two independent layers, so a bypass at one is caught by the
  other — and its two worst anti-patterns (per-tenant GitOps appliers bound to cluster-admin;
  the platform's own namespaces exempted from its own network guardrails) were both used as
  probes against this platform. The probes found real holes.

---

## Context

**Hole 1 — tenants could defeat their own isolation contract, confirmed live, not
hypothesized.** `tenant-editors` bound the built-in `edit` ClusterRole, and `edit` includes
create/update/delete on NetworkPolicies. Kubernetes NetworkPolicies are additive-permissive:
any policy that allows traffic wins. So a tenant principal could create one allow-everything
egress policy — or simply **delete `default-deny-egress`** — and quietly disable ADR-0022
D22-4's live-verified egress baseline (the metadata-server / API-server / cross-tenant-IP
blocking). Confirmed on the running cluster before the fix:
`kubectl auth can-i create networkpolicies -n abf --as-group=abf-data-engineers@company.com`
→ `yes` (delete: also `yes`).

**Hole 2 — the platform's own namespace was the only default-allow namespace on the cluster.**
Tenant namespaces get default-deny both directions; `platform-system` (the shared Temporal
control plane) had no NetworkPolicies at all. This is the weaker form of the reference
platform's "exempt our own namespaces" anti-pattern, and the same shape of hole: a compromised
platform pod had unrestricted reach.

**A constraint that dictates the layering order, verified against the live webhook config:**
Gatekeeper's `ValidatingWebhookConfiguration` registers **CREATE and UPDATE only**. Admission
control never sees a DELETE — so "Gatekeeper denies tenant NetworkPolicy writes" cannot, alone,
stop the deletion path. RBAC must be the primary layer; admission is the backstop.

## Decision

**D23-1. RBAC is the primary layer: tenants never hold NetworkPolicy verbs at all**
(`tenant-namespace` v0.13.0). The `edit` grant is replaced by:
- built-in `view` (read-only; deliberately excludes Secrets), plus
- a namespaced `tenant-operators` Role shaped by the actual delivery contract: Secrets CRUD
  (the ADR-0020 `secret_ref` contract has a human pre-create app Secrets), `pods/log`,
  `pods/exec`, `pods/portforward`.

`edit` was a leftover default, not a considered grant: workloads arrive via GitOps (ADR-0017),
never kubectl, so hand-editing Deployments was never a supported tenant action — Config Sync
would fight it anyway. A legitimate new tenant need extends the `tenant-operators` rule list
(a reviewable diff), never falls back to `edit`. Supersedes ADR-0013's "group → `edit`" detail.

**D23-2. Admission backstop: `K8sPlatformOnlyNetworkPolicy`**
(`gitops/cluster/deny-tenant-netpol.yaml`). NetworkPolicy CREATE/UPDATE in any tenant-labeled
namespace is denied unless the requester is on an explicit allow-list (parameterized; kind mode:
`kubeadm:cluster-admins`, confirmed via `kubectl auth whoami`, not assumed). Deny-by-default
**includes Config Sync's own reconciler**: Terraform owns tenant NetworkPolicies (ADR-0012), so
a NetworkPolicy appearing in the synced payload is an ownership violation the constraint
correctly refuses — the ADR-0012 boundary, now enforced at admission rather than only by CI.
Stated limit, not hidden: no DELETE coverage (webhook registration); D23-1 alone closes the
delete path. At activation, the Connect Gateway applier principal must be added to the
allow-list BEFORE the first tenant apply, or Terraform denies itself (VERIFICATION.md row).

**D23-3. `platform-system` gets default-deny both directions with exactly ONE scoped
exception** (`gitops/cluster/platform-system-netpol.yaml`): tenant-labeled namespaces →
`app: temporal-dev-server` pods, port 7233/TCP. Not a namespace-level exemption — an exact
pod+port allow. The dev-server web UI (8233) is deliberately not opened: humans reach it via
`kubectl port-forward`, which rides the kubelet path and is not subject to CNI policy. Doctrine
going forward: any future platform-system workload brings its own scoped rule; if it can't name
its pod and port, it isn't ready to deploy there. Effective tenant→Temporal reachability is now
the intersection of the tenant-side egress allow (namespace-level, ADR-0022) and this
platform-side ingress allow (pod+port): 7233 and nothing else.

## Consequences

- **All three layers live-verified 2026-07-17** (evidence in `docs/VERIFICATION.md`): the
  tenant group's allow-all egress attack denied by Gatekeeper with an attributable message; the
  platform applier's create/delete admitted; post-apply `can-i` battery — six writes that must
  be `no` are `no`, eight contract actions that must be `yes` are `yes`; from a tenant pod,
  Temporal 7233 still connects while 8233 (previously reachable) times out; the full
  pod-kill-and-resume acceptance demo passes end-to-end with everything in place.
- **A real demo-harness bug surfaced by the verification, not by review:** the demo's poller
  check (`temporal … | grep -q`) returned SIGPIPE (rc 141) under the script's own
  `set -o pipefail` once the poller table grew past one pipe flush — a successful match
  reported as failure. It passed on 2026-07-08 only because the table was small. Fixed in the
  same batch (plain `grep … >/dev/null`, which consumes all input). The platform seam itself
  measured healthy throughout: worker pod Ready in ~3s, replacement poller registered
  server-side in ~12s.
- ADR-0022 D22-4's egress baseline is now tamper-proof from inside a tenant namespace: the
  verbs are gone (D23-1) and the write path is identity-gated at admission (D23-2).
- Tenants lose kubectl write access to workload objects they never legitimately had a
  supported path to mutate. The operate role is the explicit, reviewable contract of what
  tenant humans may touch.
- Activation rows added to `VERIFICATION.md`: the applier's real principal in the constraint
  allow-list; Google Groups RBAC honoring the narrowed role on GKE.
- Remaining, accepted: DELETE is invisible to the admission layer (webhook registers
  CREATE/UPDATE only). Revisit only if a second writer identity ever joins the allow-list.
