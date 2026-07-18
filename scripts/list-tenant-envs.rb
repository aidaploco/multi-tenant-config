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
#          "_expected":{env -> [slugs]}}                # incl. offboarding (orphan check)
require "yaml"
require "json"

by_env = Hash.new { |h, k| h[k] = [] }
expected = Hash.new { |h, k| h[k] = [] }
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
puts JSON.generate(by_env.merge("_pairs" => pairs, "_expected" => expected))
