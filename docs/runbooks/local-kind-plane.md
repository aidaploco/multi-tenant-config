# Runbook: standing up the local kind runtime plane

The decision and rationale live in [ADR-0018](../adr/0018-kind-runtime-plane-and-exact-ksa.md).
This is the step list for `scripts/kind/up.sh` — the mock-first runtime plane (kind cluster +
local registry + Gatekeeper OSS + Config Sync OSS), which applies the *same*
`terraform/tenant-runtime` resources a real GKE cluster would, with zero GCP credentials.

## Prerequisites (every time)

```
open -a Docker
```
Wait for Docker Desktop's whale icon to stop animating — everything below needs the daemon
running. Also needs `kind` and `kubectl` on `PATH` (`brew install kind kubectl` if missing).

> **cgroup note for this machine:** Kubernetes ≥ 1.34's kubelet refuses to start under cgroup
> v1, and this Mac's Docker Desktop VM runs cgroup v1 (`docker info | grep -i cgroup`). That's
> why `up.sh` pins the kind node image to `v1.33.12` instead of kind's default. If Docker
> Desktop is ever upgraded to cgroup v2, the pin in `scripts/kind/up.sh` can move up.

## 1. Spin it up

```
cd ~/vscode/multi-tenant-config
bash scripts/kind/up.sh dev
```

Creates the kind cluster (`runtime-dev`), the local image registry (`localhost:5001` — the
host `scripts/render-payload.rb` pins images to), installs Gatekeeper OSS and Config Sync OSS.

**On a fresh cluster this stops partway** with `secret 'git-creds' not found` — expected, see
step 2. On a cluster that already has the secret, it completes in one pass.

## 2. Give Config Sync read access to this (private) repo — once per fresh cluster

OSS Config Sync has no Secret-Manager-token path (that's the Fleet/GKE install's trick, ADR-0012
D12-4) — it needs a token Secret up front instead.

1. Create a token at https://github.com/settings/personal-access-tokens/new:
   - **Repository access:** only `aidaploco/multi-tenant-config`.
   - **Permissions → Contents:** Read-only. Nothing else.
   - Expiration: 30 days is fine for local dev.
2. In your terminal (not through an assistant — keep the token out of any transcript):
   ```
   export GH_TOKEN=paste_your_token_here
   kubectl --context kind-runtime-dev create secret generic git-creds -n config-management-system \
     --from-literal=username=<your-github-username> --from-literal=token="$GH_TOKEN"
   unset GH_TOKEN
   ```

## 3. Re-run up.sh to finish wiring Config Sync

```
bash scripts/kind/up.sh dev
```
Completes this time and prints the `terraform apply` command below.

## 4. Apply the tenant isolation contract

```
terraform -chdir=terraform/tenant-runtime init
terraform -chdir=terraform/tenant-runtime apply -var environment=dev -var cluster_mode=kind
```
Creates, per opted-in shared-compute tenant: the namespace, both default-deny/allow-same
NetworkPolicies, ResourceQuota + LimitRange, the owner group's RoleBinding, and one KSA per
agent-unit (annotated with the `unit-ksas` allowlist the exact-KSA constraint reads).

## Verify it end-to-end

```
# The isolation contract landed
kubectl --context kind-runtime-dev get namespace abf -o yaml
kubectl --context kind-runtime-dev get networkpolicy,resourcequota,rolebinding,serviceaccount -n abf

# Config Sync is reconciling (cluster baseline + the dev-scoped payload only)
kubectl --context kind-runtime-dev get rootsync -n config-management-system root-sync -o yaml
kubectl --context kind-runtime-dev get deploy,svc -n abf

# Gatekeeper actually enforces both constraints (not just exists with 0 violations)
kubectl --context kind-runtime-dev run bad1 --image=nginx -n abf \
  --overrides='{"spec":{"serviceAccountName":"default"}}' --dry-run=server   # expect: denied

kubectl --context kind-runtime-dev create serviceaccount snoop -n abf
kubectl --context kind-runtime-dev run bad2 --image=nginx -n abf \
  --overrides='{"spec":{"serviceAccountName":"snoop"}}' --dry-run=server    # expect: denied
kubectl --context kind-runtime-dev delete serviceaccount snoop -n abf

kubectl --context kind-runtime-dev run good --image=nginx -n abf \
  --overrides='{"spec":{"serviceAccountName":"search-a"}}' --dry-run=server  # expect: admitted

# The renderer matches the registry (no drift)
ruby scripts/render-payload.rb
git status --short gitops/payload   # expect: clean
```

## Tear down

```
bash scripts/kind/down.sh dev
```
Deletes the kind cluster, the git-ignored `backend_override.tf`, and local Terraform state. The
registry container is kept (images survive an up/down cycle) — remove it separately if wanted:
`docker rm -f kind-registry`.

## Caveats

- The `google` Terraform provider still calls `Configure()` even with zero resources
  referencing it in kind mode, so `providers.tf` sets a placeholder `access_token` there —
  never sent anywhere, just skips an Application Default Credentials lookup that would
  otherwise fail with no GCP org.
- `cluster_mode = kind` bypasses Connect Gateway entirely by design — it does not verify
  anything about the real Fleet/GKE transport path (`docs/VERIFICATION.md` row 4).
