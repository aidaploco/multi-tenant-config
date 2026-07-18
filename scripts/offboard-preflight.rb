#!/usr/bin/env ruby
# Offboard preflight (ADR-0026 D26-1) — the refusal battery the offboard pipeline runs BEFORE
# any credentialed job. Pure Ruby, no cloud: a destroy that should never start must fail here,
# in seconds, with a reason.
#
# The load-bearing check is the ordering one: the tenant's payload must already be GONE from
# gitops/payload/ (i.e. the `offboarding: true` flag PR merged and the empty re-render with it)
# before any Terraform destroy is allowed. Config Sync prunes workloads from that earlier merge;
# this script is how the pipeline refuses to run out of order.
#
# Usage: ruby scripts/offboard-preflight.rb <slug>
# On success prints the tenant's declared environments as JSON (the pipeline's env fan-out).
require "yaml"
require "json"

REPO_ROOT = File.expand_path(File.join(__dir__, ".."))

def die(msg)
  warn "::error::offboard preflight: #{msg}"
  exit 1
end

slug = ARGV[0].to_s
die "usage: offboard-preflight.rb <slug>" if slug.empty?
die "slug '#{slug}' is not a valid tenant slug ([a-z0-9-])" unless slug.match?(/\A[a-z][a-z0-9-]*\z/)

tenant_file = File.join(REPO_ROOT, "tenants", "#{slug}.yaml")
die "tenants/#{slug}.yaml does not exist — nothing to offboard (already removed?)" unless File.exist?(tenant_file)

tenant = YAML.load_file(tenant_file)
unless tenant["offboarding"] == true
  die "tenants/#{slug}.yaml does not set `offboarding: true` — merge the flag PR first " \
      "(it prunes the payload and freezes the tenant out of CI; see docs/runbooks/tenant-offboard.md)"
end

leftovers = Dir.glob(File.join(REPO_ROOT, "gitops", "payload", "*", slug, "*"))
unless leftovers.empty?
  rel = leftovers.map { |p| p.sub("#{REPO_ROOT}/", "") }
  die "payload still present for '#{slug}' (#{rel.join(", ")}) — the flag merged but the " \
      "re-render didn't, or the render is stale. Destroying now would break prune-before-destroy."
end

envs = (tenant["environments"] || {}).keys
die "tenants/#{slug}.yaml declares no environments" if envs.empty?

puts JSON.generate(envs)
