# ADR-0025: Substrate CMEK + alerts that terminate somewhere — closing the reference review

- **Status:** Accepted
- **Date:** 2026-07-17
- **Builds on:** ADR-0006 (cross-cutting controls — CMEK coverage and the runbook-link OPA rule
  this extends), ADR-0009 (the GKE cluster this encrypts), ADR-0002 (the registry fields —
  `owner_group`, `budget_usd` — that were already carrying exactly the data these features
  need).
- **Origin:** the last two adopted items from the reference-platform review (PLAN.md
  "Reference-platform review outcomes"). Unlike ADR-0023/0024, both are **cloud-gated**:
  code-complete + register rows, per the mock-first discipline — nothing here can be proven on
  kind, and nothing below claims otherwise.

---

## Context

Two gaps the review surfaced remained open. First, the reference encrypts the *boring*
surfaces — cluster OS disks, data disks, backups — while our CMEK story stopped at tenant data
(GCS via kms-tenant): the shared cluster's etcd secrets and node boot disks ride Google-managed
keys, confirmed by reading the module (no `database_encryption`, no boot-disk key). Second,
the reference's ancestor stack shipped alert rules with alertmanager disabled and no receivers
— alerts that terminate nowhere — and our own observability module currently has the same
latent shape: it *consumes* `notification_channels` by ID, but nothing anywhere creates a
channel, and nothing fails when the list is empty.

## Decision

**D25-1. The cluster substrate gets platform-CMEK, and the module refuses to build without
it** (`gke-autopilot` v0.14.0). `database_encryption` (application-layer secrets in etcd) and
the node boot-disk key are new **required** variables — no default, no empty-string escape:
the same fail-closed posture as kms-tenant's `rotation_period` validation. A cluster without
substrate CMEK must be a deliberate, visible fork of the module, not a forgotten argument.
- The keys come from a `kms-tenant` instance in the **runtime project itself** — a stated
  deviation from the tenant pattern (dedicated keys project, separation of duties): here both
  the keys and the encrypted resources are platform-owned, so the separation buys little; if
  activation lands an org structure with a platform keys project, move them then (register
  row).
- Two keys, not one (`gke-secrets`, `gke-disks`): independent rotation and blast radius per
  surface.
- The service-agent grants live in the runtime root, next to the cluster that needs them:
  GKE's service agent (`container-engine-robot`) must encrypt/decrypt the secrets key, the
  Compute agent (`compute-system`) the disk key. Grant *ordering* against first cluster
  creation is exactly the kind of seam only a live apply can confirm — register row, same as
  the GCS agent-grant row (#8).
- Restated from the PLAN bullet so it lives in a decision record: **per-tenant CMEK on shared
  cluster disks is physically impossible** — one node's boot disk hosts many tenants' pods.
  This is a platform key protecting platform substrate; tenant-data CMEK remains per-tenant in
  tenant projects. A tenant whose compliance regime requires tenant-held keys under the
  workload is the `restricted`/dedicated-compute tier's problem, by design (ADR-0001 D14).

**D25-2. Every alert terminates in an owned channel, enforced three ways.**
- *Creation:* the tenant composition creates one `google_monitoring_notification_channel`
  (type `email`) per tenant project, addressed to the registry's `owner_group` — the field
  ADR-0002 has carried since day one; no new registry schema, no routing table. The reference's
  portable lesson ("rules carry labels → one funnel → ticketing routes") is deliberately NOT
  copied: our alerts already live in per-tenant projects, so the resource boundary *is* the
  routing. A `severity` user-label is added for any future aggregation layer.
- *Wiring:* the channel feeds every observability-module invocation (`notification_channels`
  was already the interface) and the new budget.
- *Enforcement:* an OPA rule (policies v0.14.0) denies any `google_monitoring_alert_policy`
  with zero notification channels — the exact companion of the existing runbook-link rule.
  Plan-time subtlety handled explicitly: channels created in the same plan are unknown at plan
  time (`after_unknown`), and the rule accepts that case rather than false-denying every
  fresh-tenant apply.

**D25-3. `budget_usd` becomes a real `google_billing_budget`** — the registry field has been
plan-decoration since ADR-0002; now each tenant environment gets a budget on the billing
account, filtered to its project, with 50%/90%/100% threshold alerts to the D25-2 channel and
`disable_default_iam_recipients = true` (the owner group is the owner, not whoever happens to
hold IAM). The billing-budgets API quota-project requirement and actual email delivery are
activation-only — register row.

## Consequences

- Register: row 12 narrows to delivery-verification only (channels/budgets now exist in
  code); new row covers substrate-CMEK agent-grant ordering, the Autopilot boot-disk-key
  field being accepted as written, budgets API quota project, and the runtime-project keys
  placement revisit.
- Verified locally (the only halves that can be): `terraform test` mocks for module wiring,
  `opa test` for both new-rule branches (deny on empty, allow on populated, allow on
  plan-time-unknown), `terraform validate` against the real provider schemas for every
  touched root.
- The reference-platform review is now fully closed: 2 ideas already ours, 2 adopted and
  live-verified (ADR-0023/0024), 2 adopted code-complete here, 0 of its anti-patterns copied.
