#!/usr/bin/env ruby
# Emit the per-tenant CI matrix from the registry (ADR-0014). Each (tenant, environment) is one
# workspace apply. Ruby is preinstalled on GitHub runners.
#
# Tenants with `offboarding: true` (ADR-0026 D26-1) are FROZEN out of every matrix: once the
# offboard starts, no plan/apply/drift job may touch their workspace again — otherwise a deploy
# run between the pipeline's destroy and the registry-removal merge would resurrect the tenant.
# They still appear in `_expected` so the orphan-workspace check knows their (still-existing)
# workspaces are a mid-offboard state, not orphans.
#
# Output: {"dev":[slugs], "acc":[...], "prod":[...],   # per-env lists (ordered deploy/plan)
#          "_pairs":[{tenant,environment}, ...],        # flat pairs (drift)
#          "_has":{dev,acc,prod,any -> bool}            # non-empty flags for job `if:` guards
#          "_expected":{env -> [slugs]}}                # incl. offboarding (orphan check)
require "yaml"
require "json"

# Every env is always present (possibly empty): a workflow that reads `.acc` off a missing key
# gets null, and a matrix over null/[] fails the run — see the length() guards in the workflows.
ENVS = %w[dev acc prod].freeze
by_env = Hash.new { |h, k| h[k] = [] }
expected = Hash.new { |h, k| h[k] = [] }
ENVS.each { |e| by_env[e]; expected[e] }
pairs = []
Dir.glob(File.join(__dir__, "..", "tenants", "*.yaml")).sort.each do |f|
  t = YAML.load_file(f)
  (t["environments"] || {}).keys.each do |env|
    expected[env] << t["slug"]
    next if t["offboarding"] == true
    by_env[env] << t["slug"]
    pairs << { "tenant" => t["slug"], "environment" => env }
  end
end
# `_has` exists because Actions expressions have no length(): jobs guard on it so an env with no
# tenants skips its matrix job instead of failing the run on an empty matrix.
has = ENVS.to_h { |e| [e, !by_env[e].empty?] }.merge("any" => !pairs.empty?)
puts JSON.generate(by_env.merge("_pairs" => pairs, "_expected" => expected, "_has" => has))
