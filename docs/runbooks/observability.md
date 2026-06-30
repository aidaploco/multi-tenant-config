# Runbook: observability baseline

The default runbook every platform-shipped alert links to (see ADR-0006 and the `observability`
module). Replace/extend per alert type as real alerts accumulate.

## Egress spike (`<resource> - egress spike`)

A monitored resource sent more bytes than its threshold over the alignment window.

1. **Identify** the resource from the alert's `display_name` (e.g. `abf-dev-landing`) and its
   tenant/environment labels.
2. **Triage** — is this expected (a legitimate large export/backfill) or anomalous?
3. **If anomalous:** check the tenant project's audit logs for the principal and operation; confirm
   it is the tenant's own Workload-Identity SA and not an unexpected identity.
4. **Contain** if needed: the tenant project is its own boundary — revoke the offending grant or
   quarantine per the runaway-tenant control.
5. **Record** the outcome and tune `egress_threshold_bytes` for this resource if the baseline was
   simply wrong.

## General

- Notification channels are per-tenant (passed into the module), so an alert already tells you
  which tenant to look at.
- Alerts cannot be silently dropped: the OPA gate requires every alert to link a runbook, and the
  platform always ships the baseline (ADR-0006).
