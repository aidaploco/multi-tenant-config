#!/usr/bin/env ruby
# Registry schema guard — runs in CI with no cloud credentials, so bad tenant data fails the PR
# in seconds instead of failing a credentialed plan later.
#
# The load-bearing invariant: Terraform roots key tenants by FILENAME (fileset + trimsuffix)
# while the CI matrix and workspaces key them by the `slug:` field (scripts/list-tenant-envs.rb).
# If those diverge, the workspace guard fails late with a confusing "not a tenant" error. The
# tenant module also validates unit types at plan time (terraform_data.guardrails); this mirrors
# the cheap checks up front.
require "yaml"

VALID_ENVS = %w[dev acc prod].freeze
# Exactly ADR-0001 D14's three values -- no more, no less. "public" was never a real
# classification anywhere in this repo (checked: zero other references) and let a tenant
# declare an isolation level D14 doesn't define.
VALID_CLASSIFICATIONS = %w[internal confidential restricted].freeze
VALID_UNIT_TYPES = %w[data-unit app-unit agent-unit].freeze

errors = []

Dir.glob(File.join(__dir__, "..", "tenants", "*.yaml")).sort.each do |f|
  name = File.basename(f, ".yaml")
  t = YAML.load_file(f)

  errors << "#{name}: slug '#{t["slug"]}' must equal the filename '#{name}'" unless t["slug"] == name
  errors << "#{name}: owner_group must be a group email" unless t["owner_group"].to_s.include?("@")
  unless VALID_CLASSIFICATIONS.include?(t["data_classification"])
    errors << "#{name}: data_classification '#{t["data_classification"]}' not one of: #{VALID_CLASSIFICATIONS.join(", ")}"
  end

  # The offboard trigger (ADR-0026 D26-1) is a strict boolean: a typo like `offboarding: yes-ish`
  # must fail the PR, not silently leave the tenant deployed.
  unless [nil, true, false].include?(t["offboarding"])
    errors << "#{name}: offboarding must be true or false (got '#{t["offboarding"]}')"
  end

  envs = t["environments"] || {}
  errors << "#{name}: declares no environments" if envs.empty?
  (envs.keys - VALID_ENVS).each { |e| errors << "#{name}: unknown environment '#{e}'" }

  unit_maps = [t.dig("defaults", "units") || {}] + envs.values.map { |v| (v || {}).fetch("units", {}) }
  unit_maps.each do |units|
    units.each do |uname, u|
      type = (u || {})["type"]
      errors << "#{name}: unit '#{uname}' has unknown type '#{type}' (one of: #{VALID_UNIT_TYPES.join(", ")})" unless VALID_UNIT_TYPES.include?(type)
    end
  end
end

if errors.empty?
  puts "registry OK — every tenant YAML is well-formed (slug==filename, known envs/types)"
else
  errors.each { |e| warn "::error::#{e}" }
  exit 1
end
