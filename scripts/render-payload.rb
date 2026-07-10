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

# Local demo pulls from kind's local registry (ADR-0017 D17-4). At activation: change this to
# the Artifact Registry host, re-render, and commit — the diff IS the migration.
IMAGE_REGISTRY = "localhost:5001".freeze

# The Temporal dev server's in-cluster Service DNS (ADR-0019; gitops/cluster/temporal-dev-server.yaml).
# At activation this becomes a Temporal Cloud endpoint — same env var, different value, no
# renderer change (mirrors IMAGE_REGISTRY's activation story).
TEMPORAL_ADDRESS = "temporal-frontend.platform-system.svc.cluster.local:7233".freeze

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
  # manifest_ref/packs_ref (ADR-0021) mount ConfigMaps a human/CI pre-creates — content, not
  # secrets, but still NOT GitOps-tracked yet (a known, accepted gap for now). Unlike secrets,
  # these are wired up only when the unit actually declares them.
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

def render(tenants_dir, out_dir)
  FileUtils.rm_rf(out_dir)

  Dir.glob(File.join(tenants_dir, "*.yaml")).sort.each do |f|
    tenant = YAML.load_file(f)
    slug   = tenant["slug"]

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

        dir = File.join(out_dir, env, slug)
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "#{unit}.yaml"),
                   manifest(slug: slug, env: env, unit: unit, image: image, version: version,
                            task_queue: task_queue, command: command, port: port,
                            expose_port: expose_port, secret_ref: secret_ref,
                            manifest_ref: manifest_ref, packs_ref: packs_ref))
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  repo_root   = File.expand_path(File.join(__dir__, ".."))
  tenants_dir = File.join(repo_root, "tenants")
  payload_dir = File.join(repo_root, "gitops", "payload")
  check       = false

  OptionParser.new do |o|
    o.on("--check") { check = true }
    o.on("--tenants-dir DIR") { |d| tenants_dir = d }
    o.on("--out-dir DIR") { |d| payload_dir = d }
  end.parse!

  if check
    Dir.mktmpdir do |tmp|
      rendered = File.join(tmp, "payload")
      render(tenants_dir, rendered)
      # diff -N so a file existing on only one side is a diff, not an error; both dirs must
      # exist for -r, and an empty render legitimately creates nothing.
      FileUtils.mkdir_p(rendered)
      FileUtils.mkdir_p(payload_dir)
      unless system("diff", "-ruN", payload_dir, rendered)
        die "gitops/payload/ is stale — the registry changed (or a generated file was hand-edited). Run: ruby scripts/render-payload.rb"
      end
      puts "payload OK — gitops/payload/ matches the registry"
    end
  else
    render(tenants_dir, payload_dir)
    puts "rendered gitops/payload/ from #{Dir.glob(File.join(tenants_dir, "*.yaml")).size} tenant file(s)"
  end
end
