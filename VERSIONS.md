# Module versions

Single source of truth for which version of every `platform-modules` module is deployed.
**Upgrading a module = bump the ref here + in the Terraform source + open a PR.** A CI check
enforces that the `?ref=` in the Terraform matches the version recorded here.

Modules are consumed from:
`git::https://github.com/aidaploco/multi-tenant-platform.git//modules/<name>?ref=<version>`

| Module | Version | Notes |
| ------ | ------- | ----- |
| `gcp-project` | `v0.1.0` | Tenant project + APIs + labels |
| `kms-tenant` | `v0.1.0` | Per-tenant CMEK keyring + keys |
| `gcs` | `v0.1.0` | CMEK-encrypted, private buckets |
| `observability` | `v0.1.0` | Log sink + alerts + dashboard |

> `v0.1.0` is the initial MVP module library. Going forward, `platform-modules` versions are
> cut automatically by semantic-release on merge to `main` (conventional commits).
