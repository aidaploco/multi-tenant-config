#!/usr/bin/env ruby
# The workload delivery renderer (ADR-0017): a pure function registry -> app-payload manifests,
# stamped into the Config-Sync-synced tree as reviewable committed diffs.
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

# Valid image tag (docker tag grammar, no "latest" — registry honesty: pin a release).
TAG_RE = /\A[\w][\w.\-]{0,127}\z/

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

def manifest(slug:, env:, unit:, image:, version:)
  <<~YAML
    # GENERATED — do not edit (ADR-0017). Rendered from tenants/#{slug}.yaml by
    # scripts/render-payload.rb; edit the registry and re-render. CI rejects drift.
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: #{unit}
      namespace: #{slug}
      annotations:
        configsync.gke.io/cluster-name-selector: runtime-#{env}
      labels:
        app: #{unit}
        tenant: #{slug}
        environment: #{env}
        app.kubernetes.io/version: "#{version}"
    spec:
      replicas: 1
      selector:
        matchLabels:
          app: #{unit}
      template:
        metadata:
          labels:
            app: #{unit}
            tenant: #{slug}
            environment: #{env}
        spec:
          # The unit's KSA — same name agent-identity binds for Workload Identity; never the
          # namespace default SA (blocked cluster-wide by deny-default-sa, ADR-0015).
          serviceAccountName: #{unit}
          containers:
            - name: #{unit}
              image: #{image}
              ports:
                - containerPort: 8080
              resources:
                requests:
                  cpu: 100m
                  memory: 128Mi
                limits:
                  cpu: 500m
                  memory: 512Mi
    ---
    apiVersion: v1
    kind: Service
    metadata:
      name: #{unit}
      namespace: #{slug}
      annotations:
        configsync.gke.io/cluster-name-selector: runtime-#{env}
      labels:
        app: #{unit}
        tenant: #{slug}
        environment: #{env}
    spec:
      selector:
        app: #{unit}
      ports:
        - port: 8080
          targetPort: 8080
  YAML
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

        image = "#{IMAGE_REGISTRY}/#{u.fetch("image", unit)}:#{version}"
        dir   = File.join(out_dir, env, slug)
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "#{unit}.yaml"),
                   manifest(slug: slug, env: env, unit: unit, image: image, version: version))
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
