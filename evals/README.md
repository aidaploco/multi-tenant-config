# evals/ — evidence for prod promotions (ADR-0026 D26-4)

Since ADR-0017 a unit's prod `version` **is** the deployed image tag, so bumping it is the
promotion mechanism — and until now nothing distinguished a tested prod bump from a typo. CI
(`scripts/check-eval-gate.rb`, in the guards job) refuses any PR that changes a unit's
*effective* prod version unless this directory holds a passing eval report for exactly that
release:

```
evals/<tenant>/<unit>/<version>.yaml
```

```yaml
unit: cs-agent-api          # must match the directory
version: 0.2.2              # must match the filename
verdict: pass               # anything else refuses the promotion
date: 2026-07-18
evidence: "https://github.com/…/actions/runs/…  (eval suite run: 47/47 scenarios)"
summary: "Optional: what was evaluated and the headline numbers."
```

The report is produced by the **application repo's** eval suite (the platform doesn't run
evals — it demands their evidence, the same split as ADR-0020's delivery contract) and is
committed in the same PR as the version bump.

Deliberate scope:

- **Prod only, opted-in agent-units only** — the one archetype with a delivery path. dev/acc
  bumps stay friction-free; dev running ahead is the designed workflow.
- **Only changed versions are gated.** Reports are permanent: a **rollback** to a
  previously-promoted version needs no new report — its report exists from the original
  promotion, so rollback speed is never taxed (ADR-0007's posture).
- A **new tenant** (or unit) arriving in prod is a first promotion and needs a report like any
  other.
- `verdict` is binary. There is no `pass-with-notes`; if it didn't pass, it doesn't promote.

Nothing here is retroactive: versions already in prod when the gate landed need no backfilled
report (fabricating evidence for evals that never ran would defeat the point).
