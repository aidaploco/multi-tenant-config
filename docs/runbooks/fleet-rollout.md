# Runbook: rolling out a module version across the fleet

The decision and rationale live in [ADR-0007](../adr/0007-fleet-rollout-and-rollback.md). This is
the step list. Example: upgrading `gcs` from `v0.1.0` to `v0.2.0`.

## Upgrade (canary → promote → bulk)

1. **Canary, dev, one tenant.** In that tenant's `tenants/<slug>.yaml`, pin the relevant layer to
   the new version under the `dev` environment only. Open a PR.
   - CI plans all envs and posts the diff; the OPA gate must pass.
   - Merge → auto-apply dev. **Soak** (hours/days, per your risk appetite).
2. **Promote the canary.** Approve the `acc` then `prod` deployments for that tenant. Each gate is
   a soak boundary — do not approve `prod` until `acc` has been healthy.
3. **Bulk.** Once the canary is proven, in **one PR**: bump the version in `VERSIONS.md` and the
   literal `?ref=` in `terraform/tenants/modules/tenant/main.tf` (and remove the per-tenant canary
   override). CI enforces that the refs match `VERSIONS.md`.
   - Merge → dev → acc → prod, approving each gate.

## Rollback

1. `git revert` the offending PR (canary or bulk).
2. CI plans the **downgrade**; read it — confirm it is not destroying/recreating data-bearing
   resources unexpectedly.
3. Merge → apply. Rollback follows the same dev→acc→prod path.

> **Caveat (ADR-0005):** state is shared per environment. A bulk rollback rolls back the whole
> environment, not a single tenant. For state-bearing modules (KMS, buckets), verify the downgrade
> is reversible *before* relying on rollback — some resources do not cleanly revert.

## Pre-flight checklist

- [ ] New version released and tagged in `multi-tenant-platform`.
- [ ] `VERSIONS.md` and `?ref=` agree (CI checks this).
- [ ] Plan reviewed; destroy count within the OPA threshold.
- [ ] Canary soaked through acc before any bulk change.
