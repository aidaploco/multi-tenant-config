#!/usr/bin/env ruby
# The workload delivery renderer (ADR-0017, extended by ADR-0020): a pure function
# registry -> app-payload manifests, stamped into the Config-Sync-synced tree as reviewable
# committed diffs.
#
# This is ADR-0004's generator graduation invoked SURGICALLY: only the k8s app payload is
# generated (Terraform stays data-driven), and the generated-vs-custom split is hard — every
# file under gitops/payload/ is regenerated from scratch each run and never hand-edited. The
# prune-and-rewrite is load-bearing: removing a unit/tenant from the registry removes its
# payload file, so Config Sync prunes the workload BEFORE Terraform ever destroys the
# namespace (the offboard ordering).
#
# Usage:
#   ruby scripts/render-payload.rb            # re-render gitops/payload/ in place
#   ruby scripts/render-payload.rb --check    # exit 1 if committed payload != rendered (CI)
# Test hooks: --tenants-dir DIR / --out-dir DIR (used by scripts/test-render-payload.rb).
require "yaml"
require "fileutils"
require "optparse"
require "tmpdir"

# File.read tags a String's encoding from the ambient locale (Encoding.default_external), not
# from the bytes actually read. Registry comments and config/ pack files contain real UTF-8
# (em-dashes); under a non-UTF-8 locale (LANG=C — plausible on a minimal CI image or a fresh
# contributor's machine) those Strings get mistagged as US-ASCII, and Psych's YAML.dump raises
# ("invalid byte sequence in US-ASCII") the moment it tries to serialize one. Fixed globally
# here rather than per File.read call: a future read site that forgets an explicit `encoding:`
# argument would silently reintroduce this exact bug.
Encoding.default_external = Encoding::UTF_8

# Local demo pulls from kind's local registry (ADR-0017 D17-4). At activation: change this to
# the Artifact Registry host, re-render, and commit — the diff IS the migration.
IMAGE_REGISTRY = "localhost:5001".freeze

# The Temporal dev server's in-cluster Service DNS (ADR-0019; gitops/cluster/temporal-dev-server.yaml).
# At activation this becomes a Temporal Cloud endpoint — same env var, different value, no
# renderer change (mirrors IMAGE_REGISTRY's activation story).
TEMPORAL_ADDRESS = "temporal-frontend.platform-system.svc.cluster.local:7233".freeze

# Per-tenant Phoenix trace backend (ADR-0027): one instance per tenant per environment, rendered
# into gitops/platform/. Pinned (registry honesty — the hub tag was checked to exist, and the
# nonroot variant matches the platform's posture); third-party platform components pull straight
# from their upstream registry, the temporalio/temporal precedent (ADR-0019).
PHOENIX_IMAGE = "arizephoenix/phoenix:15.11.1-nonroot".freeze
PHOENIX_PORT = 6006

# The tenant's OWN instance — reachability to it never crosses a tenant boundary. Same
# activation story as TEMPORAL_ADDRESS: same env var, different value, no app change.
def phoenix_endpoint(slug)
  "http://phoenix-#{slug}.platform-system.svc.cluster.local:#{PHOENIX_PORT}/v1/traces"
end

DEFAULT_PORT = 8080

# manifest_ref/packs_ref (ADR-0021): fixed mount paths + env var names, matching a specific
# app contract (MANIFEST_PATH = one file, PACKS_DIR = a directory of files) rather than a
# generic config-mount mechanism — narrow on purpose, generalize only when a second shape
# actually needs it.
MANIFEST_MOUNT_PATH = "/etc/ai-employee/manifest".freeze
MANIFEST_FILENAME = "manifest.yaml".freeze
PACKS_MOUNT_PATH = "/etc/ai-employee/packs".freeze

# Valid image tag (docker tag grammar, no "latest" — registry honesty: pin a release).
TAG_RE = /\A[\w][\w.\-]{0,127}\z/

GENERATED_HEADER = <<~COMMENT.freeze
  # GENERATED — do not edit (ADR-0017, ADR-0020). Rendered from the tenant registry by
  # scripts/render-payload.rb; edit tenants/<slug>.yaml and re-render. CI rejects drift.
  #
  # serviceAccountName is the unit's own KSA (agent-identity binds the matching GCP SA at
  # activation) — never the namespace default SA: blocked cluster-wide by deny-default-sa
  # (ADR-0015) and, more specifically, the exact-KSA constraint (ADR-0018).
  #
  # TEMPORAL_* env vars wire durable-execution connectivity (ADR-0016 D16-3, ADR-0019): the
  # local dev server here, a Temporal Cloud endpoint at activation — same three vars either way.
  #
  # envFrom references a Secret a human pre-creates (never the registry, never committed —
  # ADR-0020); `optional: true` so a missing Secret doesn't block the pod from starting.
  #
  # manifest_ref/packs_ref (ADR-0021, GitOps-tracked since ADR-0022 D22-2) render real
  # ConfigMaps from config/<tenant>/<ref>/ — reviewable committed content, not an
  # externally-created artifact. Wired up only when the unit actually declares them.
COMMENT

def die(msg)
  warn "::error::#{msg}"
  exit 1
end

# Same shallow merge the tenant module does: this env's units override defaults per unit name.
def merged_units(tenant, env)
  defaults  = tenant.dig("defaults", "units") || {}
  overrides = ((tenant["environments"] || {})[env] || {})["units"] || {}
  defaults.merge(overrides)
end

def container_spec(unit:, image:, slug:, env:, task_queue:, command:, port:, expose_port:,
                    secret_ref:, manifest_ref:, packs_ref:)
  c = { "name" => unit, "image" => image }
  c["command"] = command if command
  c["env"] = [
    { "name" => "TEMPORAL_ADDRESS", "value" => TEMPORAL_ADDRESS },
    { "name" => "TEMPORAL_NAMESPACE", "value" => "#{slug}-#{env}" },
    { "name" => "TEMPORAL_TASK_QUEUE", "value" => task_queue },
    # ADR-0027: the tenant's own Phoenix. Apps without OTLP support ignore it; apps with it
    # (both real workloads today) fail-soft when unset — so delivering it is always safe.
    { "name" => "PHOENIX_COLLECTOR_ENDPOINT", "value" => phoenix_endpoint(slug) },
  ]
  c["env"] << { "name" => "MANIFEST_PATH", "value" => "#{MANIFEST_MOUNT_PATH}/#{MANIFEST_FILENAME}" } if manifest_ref
  c["env"] << { "name" => "PACKS_DIR", "value" => PACKS_MOUNT_PATH } if packs_ref
  c["envFrom"] = [{ "secretRef" => { "name" => secret_ref, "optional" => true } }]
  c["ports"] = [{ "containerPort" => port }] if expose_port
  c["volumeMounts"] = [] if manifest_ref || packs_ref
  c["volumeMounts"] << { "name" => "manifest", "mountPath" => MANIFEST_MOUNT_PATH } if manifest_ref
  c["volumeMounts"] << { "name" => "packs", "mountPath" => PACKS_MOUNT_PATH } if packs_ref
  c["resources"] = {
    "requests" => { "cpu" => "100m", "memory" => "128Mi" },
    "limits" => { "cpu" => "500m", "memory" => "512Mi" },
  }
  c
end

def deployment_doc(slug:, env:, unit:, version:, container:, manifest_ref:, packs_ref:)
  pod_spec = { "serviceAccountName" => unit, "containers" => [container] }
  volumes = []
  volumes << { "name" => "manifest", "configMap" => { "name" => manifest_ref, "optional" => true } } if manifest_ref
  volumes << { "name" => "packs", "configMap" => { "name" => packs_ref, "optional" => true } } if packs_ref
  pod_spec["volumes"] = volumes unless volumes.empty?

  {
    "apiVersion" => "apps/v1",
    "kind" => "Deployment",
    "metadata" => {
      "name" => unit,
      "namespace" => slug,
      "annotations" => { "configsync.gke.io/cluster-name-selector" => "runtime-#{env}" },
      "labels" => { "app" => unit, "tenant" => slug, "environment" => env, "app.kubernetes.io/version" => version },
    },
    "spec" => {
      "replicas" => 1,
      "selector" => { "matchLabels" => { "app" => unit } },
      "template" => {
        "metadata" => { "labels" => { "app" => unit, "tenant" => slug, "environment" => env } },
        "spec" => pod_spec,
      },
    },
  }
end

def configmap_doc(slug:, env:, name:, data:)
  {
    "apiVersion" => "v1",
    "kind" => "ConfigMap",
    "metadata" => {
      "name" => name,
      "namespace" => slug,
      "annotations" => { "configsync.gke.io/cluster-name-selector" => "runtime-#{env}" },
      "labels" => { "tenant" => slug, "environment" => env },
    },
    "data" => data,
  }
end

# <config_dir>/<tenant>/<ref>/manifest.yaml -> a ConfigMap with one key, "manifest.yaml"
# (ADR-0022 D22-2). Dies loudly if declared but missing — once the renderer owns the content,
# an empty mount is a repo bug, not a deploy-time fact of life.
def manifest_configmap(config_dir:, slug:, env:, ref:)
  path = File.join(config_dir, slug, ref, MANIFEST_FILENAME)
  die "#{slug}/#{ref}: manifest_ref set but #{path} doesn't exist (ADR-0022 D22-2)" unless File.exist?(path)
  configmap_doc(slug: slug, env: env, name: ref, data: { MANIFEST_FILENAME => File.read(path) })
end

# <config_dir>/<tenant>/<ref>/packs/*.py -> a ConfigMap with one key per file.
def packs_configmap(config_dir:, slug:, env:, ref:)
  dir = File.join(config_dir, slug, ref, "packs")
  files = Dir.glob(File.join(dir, "*.py")).sort
  die "#{slug}/#{ref}: packs_ref set but #{dir}/ has no .py files (ADR-0022 D22-2)" if files.empty?
  data = files.each_with_object({}) { |f, h| h[File.basename(f)] = File.read(f) }
  configmap_doc(slug: slug, env: env, name: ref, data: data)
end

PLATFORM_HEADER = <<~COMMENT.freeze
  # GENERATED — do not edit (ADR-0027). Rendered from the tenant registry by
  # scripts/render-payload.rb; edit tenants/<slug>.yaml and re-render. CI rejects drift.
  #
  # One Phoenix trace backend PER TENANT per environment, in platform-system: instance-level
  # isolation instead of trusting Phoenix OSS's project namespacing as a boundary. The
  # NetworkPolicy is the boundary — only pods in the tenant's own namespace (namespaceSelector
  # on the Terraform-stamped `tenant` label) reach the collector port. Storage is PVC-backed
  # SQLite (design review 2026-07-19, the Temporal-dev-server pattern, D19-1): traces survive
  # pod restarts; Recreate strategy because SQLite is single-writer. Postgres is the ACTIVATION
  # storage (per-tenant Cloud SQL under the tenant's CMEK — ADR-0027/0028 convergence); traces
  # remain diagnostics, not the system of record — Temporal's (D16-5-encrypted) history is.
COMMENT

# The four platform-plane objects for one tenant's Phoenix instance. All in platform-system
# (never the tenant namespace — tenant RBAC must not reach the trace store), all env-scoped by
# cluster-name-selector like every payload object. ServiceAccount because deny-default-sa is
# cluster-wide (ADR-0015); the ownership guard admits these kinds here ONLY for platform-system.
def phoenix_docs(slug:, env:)
  name = "phoenix-#{slug}"
  meta = lambda do
    {
      "name" => name,
      "namespace" => "platform-system",
      "annotations" => { "configsync.gke.io/cluster-name-selector" => "runtime-#{env}" },
      "labels" => { "app" => name, "tenant" => slug, "environment" => env },
    }
  end

  pvc = {
    "apiVersion" => "v1", "kind" => "PersistentVolumeClaim", "metadata" => meta.call,
    "spec" => {
      "accessModes" => ["ReadWriteOnce"],
      "resources" => { "requests" => { "storage" => "1Gi" } },
    },
  }

  deployment = {
    "apiVersion" => "apps/v1", "kind" => "Deployment", "metadata" => meta.call,
    "spec" => {
      "replicas" => 1,
      # SQLite is single-writer: never two pods on one claim (the D19-1 Temporal precedent).
      "strategy" => { "type" => "Recreate" },
      "selector" => { "matchLabels" => { "app" => name } },
      "template" => {
        "metadata" => { "labels" => { "app" => name, "tenant" => slug, "environment" => env } },
        "spec" => {
          "serviceAccountName" => name,
          "containers" => [{
            "name" => "phoenix",
            "image" => PHOENIX_IMAGE,
            "ports" => [{ "containerPort" => PHOENIX_PORT }],
            "env" => [{ "name" => "PHOENIX_WORKING_DIR", "value" => "/mnt/data" }],
            "volumeMounts" => [{ "name" => "data", "mountPath" => "/mnt/data" }],
            "resources" => {
              "requests" => { "cpu" => "100m", "memory" => "256Mi" },
              "limits" => { "cpu" => "500m", "memory" => "1Gi" },
            },
          }],
          "volumes" => [{ "name" => "data", "persistentVolumeClaim" => { "claimName" => name } }],
        },
      },
    },
  }

  service = {
    "apiVersion" => "v1", "kind" => "Service", "metadata" => meta.call,
    "spec" => {
      "selector" => { "app" => name },
      "ports" => [{ "port" => PHOENIX_PORT, "targetPort" => PHOENIX_PORT }],
    },
  }

  netpol = {
    "apiVersion" => "networking.k8s.io/v1", "kind" => "NetworkPolicy", "metadata" => meta.call,
    "spec" => {
      "podSelector" => { "matchLabels" => { "app" => name } },
      "policyTypes" => ["Ingress"],
      "ingress" => [{
        "from" => [{ "namespaceSelector" => { "matchLabels" => { "tenant" => slug } } }],
        "ports" => [{ "protocol" => "TCP", "port" => PHOENIX_PORT }],
      }],
    },
  }

  sa = { "apiVersion" => "v1", "kind" => "ServiceAccount", "metadata" => meta.call }

  [sa, pvc, deployment, service, netpol]
end

def service_doc(slug:, env:, unit:, port:)
  {
    "apiVersion" => "v1",
    "kind" => "Service",
    "metadata" => {
      "name" => unit,
      "namespace" => slug,
      "annotations" => { "configsync.gke.io/cluster-name-selector" => "runtime-#{env}" },
      "labels" => { "app" => unit, "tenant" => slug, "environment" => env },
    },
    "spec" => { "selector" => { "app" => unit }, "ports" => [{ "port" => port, "targetPort" => port }] },
  }
end

def manifest(slug:, env:, unit:, image:, version:, task_queue:, command:, port:, expose_port:,
             secret_ref:, manifest_ref:, packs_ref:)
  container = container_spec(unit: unit, image: image, slug: slug, env: env, task_queue: task_queue,
                              command: command, port: port, expose_port: expose_port,
                              secret_ref: secret_ref, manifest_ref: manifest_ref, packs_ref: packs_ref)
  docs = [deployment_doc(slug: slug, env: env, unit: unit, version: version, container: container,
                          manifest_ref: manifest_ref, packs_ref: packs_ref)]
  docs << service_doc(slug: slug, env: env, unit: unit, port: port) if expose_port
  GENERATED_HEADER + docs.map { |d| YAML.dump(d) }.join
end

def render(tenants_dir, out_dir, config_dir:, platform_dir:)
  FileUtils.rm_rf(out_dir)
  FileUtils.rm_rf(platform_dir)

  # (env, slug) pairs that rendered at least one unit — each gets a Phoenix instance
  # (ADR-0027). Keyed off actual rendered units, not declared ones: an opted-out or
  # offboarding tenant gets no instance, and offboarding prunes it (same commit as the
  # payload prune).
  phoenix_tenants = []

  # Collected across all units first, keyed by [env, slug, ref], then written once each at the
  # end — merged, not overwritten. Two refs of the same name (a unit using one shared ConfigMap
  # for both manifest_ref and packs_ref) must combine into one object, not clobber each other.
  configmaps = {}
  collect_configmap = lambda do |doc, env, slug, ref|
    key = [env, slug, ref]
    if configmaps[key]
      configmaps[key]["data"].merge!(doc["data"])
    else
      configmaps[key] = doc
    end
  end

  Dir.glob(File.join(tenants_dir, "*.yaml")).sort.each do |f|
    tenant = YAML.load_file(f)
    slug   = tenant["slug"]

    # offboarding: true (ADR-0026 D26-1) — the payload prune IS offboarding step one. The tenant
    # YAML (and so the namespace and project) still exists, but the render is empty, so Config
    # Sync prunes every workload strictly BEFORE any Terraform destroy can run. The offboard
    # pipeline refuses to destroy until this has merged.
    next if tenant["offboarding"] == true

    (tenant["environments"] || {}).keys.sort.each do |env|
      merged_units(tenant, env).sort.each do |unit, u|
        u ||= {}
        next unless u["type"] == "agent-unit" # only built archetype renders (D17-5)
        next unless u.fetch("opt_in", true)

        # gitops/payload/ targets the SHARED runtime plane; regulated tenants never share it
        # (ADR-0001 D14) and have no delivery path until a dedicated one exists.
        if tenant["data_classification"] == "restricted"
          die "#{slug}/#{env}/#{unit}: restricted tenants cannot deliver to the shared runtime plane (ADR-0017 D17-5)"
        end

        version = u["version"].to_s
        unless version.match?(TAG_RE) && version != "latest"
          die "#{slug}/#{env}/#{unit}: opted-in agent-unit needs a pinned `version` (got '#{version}') — it is the deployed image tag (ADR-0017 D17-5)"
        end

        command = u["command"]
        if command && (!command.is_a?(Array) || command.empty? || !command.all? { |x| x.is_a?(String) })
          die "#{slug}/#{env}/#{unit}: `command` must be a non-empty array of strings (ADR-0020)"
        end

        image       = "#{IMAGE_REGISTRY}/#{u.fetch("image", unit)}:#{version}"
        task_queue  = u.fetch("task_queue", unit)
        port        = u.fetch("port", DEFAULT_PORT)
        expose_port = u.fetch("expose_port", true)
        secret_ref  = u.fetch("secret_ref", unit)
        manifest_ref = u["manifest_ref"]
        packs_ref    = u["packs_ref"]

        phoenix_tenants << [env, slug] unless phoenix_tenants.include?([env, slug])

        dir = File.join(out_dir, env, slug)
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "#{unit}.yaml"),
                   manifest(slug: slug, env: env, unit: unit, image: image, version: version,
                            task_queue: task_queue, command: command, port: port,
                            expose_port: expose_port, secret_ref: secret_ref,
                            manifest_ref: manifest_ref, packs_ref: packs_ref))

        # Named by ref, not by unit: two units sharing one manifest_ref/packs_ref (the normal
        # case — an API and a worker loading the same role) collapse into one generated
        # ConfigMap instead of two divergent copies of identical content.
        if manifest_ref
          collect_configmap.call(manifest_configmap(config_dir: config_dir, slug: slug, env: env, ref: manifest_ref), env, slug, manifest_ref)
        end
        if packs_ref
          collect_configmap.call(packs_configmap(config_dir: config_dir, slug: slug, env: env, ref: packs_ref), env, slug, packs_ref)
        end
      end
    end
  end

  configmaps.each do |(env, slug, ref), doc|
    dir = File.join(out_dir, env, slug)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "_config-#{ref}.yaml"), GENERATED_HEADER + YAML.dump(doc))
  end

  phoenix_tenants.each do |env, slug|
    dir = File.join(platform_dir, env)
    FileUtils.mkdir_p(dir)
    docs = phoenix_docs(slug: slug, env: env)
    File.write(File.join(dir, "phoenix-#{slug}.yaml"), PLATFORM_HEADER + docs.map { |d| YAML.dump(d) }.join)
  end
end

if __FILE__ == $PROGRAM_NAME
  repo_root    = File.expand_path(File.join(__dir__, ".."))
  tenants_dir  = File.join(repo_root, "tenants")
  payload_dir  = File.join(repo_root, "gitops", "payload")
  platform_dir = File.join(repo_root, "gitops", "platform")
  config_dir   = File.join(repo_root, "config")
  check        = false

  OptionParser.new do |o|
    o.on("--check") { check = true }
    o.on("--tenants-dir DIR") { |d| tenants_dir = d }
    o.on("--out-dir DIR") { |d| payload_dir = d }
    o.on("--platform-dir DIR") { |d| platform_dir = d }
    o.on("--config-dir DIR") { |d| config_dir = d }
  end.parse!

  # Both output trees are rm_rf'd on render. A test hook that redirects one but not the other
  # would silently wipe the real committed tree — refuse the half-override outright.
  overridden = [payload_dir, platform_dir].map { |d| !d.start_with?(repo_root) }
  die "test hooks must override --out-dir and --platform-dir together (both trees are pruned on render)" if overridden.uniq.size > 1

  if check
    Dir.mktmpdir do |tmp|
      rendered          = File.join(tmp, "payload")
      rendered_platform = File.join(tmp, "platform")
      render(tenants_dir, rendered, config_dir: config_dir, platform_dir: rendered_platform)
      # diff -N so a file existing on only one side is a diff, not an error; both dirs must
      # exist for -r, and an empty render legitimately creates nothing.
      [[payload_dir, rendered, "gitops/payload/"], [platform_dir, rendered_platform, "gitops/platform/"]].each do |committed, fresh, label|
        FileUtils.mkdir_p(fresh)
        FileUtils.mkdir_p(committed)
        unless system("diff", "-ruN", committed, fresh)
          die "#{label} is stale — the registry changed (or a generated file was hand-edited). Run: ruby scripts/render-payload.rb"
        end
      end
      puts "payload OK — gitops/payload/ and gitops/platform/ match the registry"
    end
  else
    render(tenants_dir, payload_dir, config_dir: config_dir, platform_dir: platform_dir)
    puts "rendered gitops/payload/ + gitops/platform/ from #{Dir.glob(File.join(tenants_dir, "*.yaml")).size} tenant file(s)"
  end
end
