#!/usr/bin/env ruby
# Eval-gated promotion (ADR-0026 D26-4): a PR that changes any unit's EFFECTIVE prod `version`
# must carry an eval report for exactly that (tenant, unit, version) — evals/<tenant>/<unit>/
# <version>.yaml with `verdict: pass`. Since ADR-0017 the prod version IS the deployed image
# tag, so this is the quality gate on the promotion mechanism itself: nothing distinguishes a
# tested prod bump from a typo until something demands evidence.
#
# Scope is deliberate:
# - Only prod, only opted-in agent-units (the one archetype with a delivery path — ADR-0017
#   D17-5); dev/acc promotions stay friction-free.
# - Only CHANGED versions are gated, and reports are permanent files: a ROLLBACK needs no new
#   report (the old version's report exists from its original promotion) — rollback speed is
#   never taxed (ADR-0007's posture).
# - Effective version = the same shallow defaults/env merge the renderer does, so a bump hidden
#   in `defaults.units` gates exactly like an explicit prod override.
#
# Usage: ruby scripts/check-eval-gate.rb [--base REF] [--repo DIR]
#   --base: registry state to diff against (CI passes the PR base SHA; default HEAD, so a local
#           run gates your uncommitted working tree).
require "yaml"
require "date"
require "optparse"
require "open3"

# Psych 4 (Ruby 3.1+, i.e. CI runners) makes YAML.load safe-by-default and REFUSES to
# construct Date — which every eval report contains (`date: 2026-07-18`). Psych 3 (older
# local rubies) happily loads it. Pin the semantics explicitly so the gate behaves the same
# everywhere: safe loading, Date permitted, nothing else.
def load_yaml(content)
  YAML.safe_load(content, permitted_classes: [Date])
end

repo_root = File.expand_path(File.join(__dir__, ".."))
base = "HEAD"
OptionParser.new do |o|
  o.on("--base REF") { |r| base = r }
  o.on("--repo DIR") { |d| repo_root = File.expand_path(d) } # test hook
end.parse!

REQUIRED_FIELDS = %w[unit version verdict date evidence].freeze

def effective_prod_units(tenant)
  return {} if tenant.nil? || tenant["offboarding"] == true
  envs = tenant["environments"] || {}
  return {} unless envs.key?("prod")
  defaults  = tenant.dig("defaults", "units") || {}
  overrides = (envs["prod"] || {})["units"] || {}
  defaults.merge(overrides).each_with_object({}) do |(name, u), h|
    u ||= {}
    next unless u["type"] == "agent-unit" && u.fetch("opt_in", true)
    v = u["version"].to_s
    h[name] = v unless v.empty?
  end
end

def base_tenants(repo_root, base)
  out, status = Open3.capture2("git", "-C", repo_root, "ls-tree", "-r", "--name-only", base, "tenants")
  unless status.success?
    warn "::error::eval gate: cannot read base ref '#{base}' (git ls-tree failed — fetch it first?)"
    exit 1
  end
  out.split("\n").grep(%r{\Atenants/[^/]+\.yaml\z}).each_with_object({}) do |path, h|
    content, st = Open3.capture2("git", "-C", repo_root, "show", "#{base}:#{path}")
    next unless st.success?
    t = load_yaml(content)
    h[t["slug"]] = t if t.is_a?(Hash)
  end
end

base_state = base_tenants(repo_root, base)
head_state = Dir.glob(File.join(repo_root, "tenants", "*.yaml")).sort.each_with_object({}) do |f, h|
  t = load_yaml(File.read(f))
  h[t["slug"]] = t if t.is_a?(Hash)
end

promotions = []
head_state.each do |slug, tenant|
  base_units = effective_prod_units(base_state[slug])
  effective_prod_units(tenant).each do |unit, version|
    promotions << [slug, unit, version] unless base_units[unit] == version
  end
end

errors = []
promotions.each do |slug, unit, version|
  report_path = File.join(repo_root, "evals", slug, unit, "#{version}.yaml")
  rel = "evals/#{slug}/#{unit}/#{version}.yaml"
  unless File.exist?(report_path)
    errors << "#{slug}/#{unit}: prod promotion to #{version} has no eval report — add #{rel} (see evals/README.md)"
    next
  end
  report = begin
    load_yaml(File.read(report_path))
  rescue Psych::Exception => e
    errors << "#{rel}: unparseable YAML (#{e.message})"
    next
  end
  report = {} unless report.is_a?(Hash)
  (REQUIRED_FIELDS - report.keys).each { |k| errors << "#{rel}: missing required field '#{k}'" }
  errors << "#{rel}: `unit` is '#{report["unit"]}', expected '#{unit}'" if report.key?("unit") && report["unit"] != unit
  errors << "#{rel}: `version` is '#{report["version"]}', expected '#{version}'" if report.key?("version") && report["version"].to_s != version
  if report.key?("verdict") && report["verdict"] != "pass"
    errors << "#{rel}: verdict is '#{report["verdict"]}' — only a passing eval may promote to prod"
  end
end

if errors.empty?
  if promotions.empty?
    puts "eval gate OK — no prod promotions vs #{base}"
  else
    puts "eval gate OK — #{promotions.size} prod promotion(s) covered by passing eval reports: " +
         promotions.map { |s, u, v| "#{s}/#{u}@#{v}" }.join(", ")
  end
else
  errors.each { |e| warn "::error::#{e}" }
  exit 1
end
