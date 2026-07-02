#!/usr/bin/env ruby
# Emit the per-tenant CI matrix from the registry (ADR-0014). Each (tenant, environment) is one
# workspace apply. Ruby is preinstalled on GitHub runners.
#
# Output: {"dev":[slugs], "acc":[...], "prod":[...],   # per-env lists (ordered deploy/plan)
#          "_pairs":[{tenant,environment}, ...]}        # flat pairs (drift)
require "yaml"
require "json"

by_env = Hash.new { |h, k| h[k] = [] }
pairs = []
Dir.glob(File.join(__dir__, "..", "tenants", "*.yaml")).sort.each do |f|
  t = YAML.load_file(f)
  (t["environments"] || {}).keys.each do |env|
    by_env[env] << t["slug"]
    pairs << { "tenant" => t["slug"], "environment" => env }
  end
end
puts JSON.generate(by_env.merge("_pairs" => pairs))
