#!/usr/bin/env ruby
# Tests for the eval-gated promotion check (ADR-0026 D26-4). Pure Ruby + git, runs in CI's
# guards job. Each case builds a throwaway git repo (the gate diffs registry states via git),
# commits a base, mutates the working tree, and asserts the gate's verdict — both directions:
# promotions without evidence must FAIL, and everything that shouldn't be taxed (no-ops,
# dev bumps, rollbacks to previously-evaluated versions) must PASS.
require "fileutils"
require "tmpdir"
require "open3"

GATE = File.join(__dir__, "check-eval-gate.rb")
failures = []

def tenant_yaml(dev_version:, prod_version:, prod_in_defaults: false)
  if prod_in_defaults
    <<~YAML
      slug: t1
      display_name: "T1"
      owner_group: t1@company.com
      data_classification: internal
      cmek_location: europe-west4
      defaults:
        units:
          chat: { type: agent-unit, version: #{prod_version}, opt_in: true }
      environments:
        dev: {}
        prod: {}
    YAML
  else
    <<~YAML
      slug: t1
      display_name: "T1"
      owner_group: t1@company.com
      data_classification: internal
      cmek_location: europe-west4
      environments:
        dev:
          units:
            chat: { type: agent-unit, version: #{dev_version}, opt_in: true }
        prod:
          units:
            chat: { type: agent-unit, version: #{prod_version}, opt_in: true }
    YAML
  end
end

def write_report(repo, unit, version, verdict: "pass", version_field: nil)
  dir = File.join(repo, "evals", "t1", unit)
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "#{version}.yaml"), <<~YAML)
    unit: #{unit}
    version: #{version_field || version}
    verdict: #{verdict}
    date: 2026-07-18
    evidence: "test fixture"
  YAML
end

# Build a repo whose committed base is tenant @ base_prod (report for it present), yield for
# working-tree mutations, then run the gate against HEAD. Returns [passed, stderr].
def run_gate(base_prod: "1.0.0", prod_in_defaults: false)
  result = nil
  Dir.mktmpdir do |repo|
    FileUtils.mkdir_p(File.join(repo, "tenants"))
    File.write(File.join(repo, "tenants", "t1.yaml"),
               tenant_yaml(dev_version: base_prod, prod_version: base_prod, prod_in_defaults: prod_in_defaults))
    write_report(repo, "chat", base_prod)
    system("git", "-C", repo, "init", "-q", out: File::NULL) or raise "git init failed"
    system("git", "-C", repo, "add", "-A", out: File::NULL) or raise
    system("git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base",
           out: File::NULL) or raise "git commit failed"
    yield repo
    _out, err, status = Open3.capture3("ruby", GATE, "--repo", repo, "--base", "HEAD")
    result = [status.success?, err]
  end
  result
end

def gate_passes(**kw, &blk)
  passed, err = run_gate(**kw, &blk)
  # A pass must be a real pass, not silence; surface unexpected stderr for debugging.
  warn err unless err.empty?
  passed
end

# A refusal must be the gate REFUSING (::error:: on stderr), never the gate crashing — a crash
# also exits nonzero, and treating it as a refusal is exactly how a Psych-4-only crash slipped
# past this suite once (the two allow-cases failed in CI while every refusal "passed").
def gate_refuses(**kw, &blk)
  passed, err = run_gate(**kw, &blk)
  !passed && err.include?("::error::")
end

bump = ->(repo, dev:, prod:, prod_in_defaults: false) do
  File.write(File.join(repo, "tenants", "t1.yaml"),
             tenant_yaml(dev_version: dev, prod_version: prod, prod_in_defaults: prod_in_defaults))
end

# 1. No registry change -> no gate.
failures << "clean tree should pass" unless gate_passes { |_| }

# 2. Prod bump with no report -> refuse (cleanly, with ::error:: — not a crash).
failures << "prod bump without a report should cleanly refuse" unless
  gate_refuses { |r| bump.(r, dev: "1.1.0", prod: "1.1.0") }

# 3. Prod bump with a passing report -> allow.
failures << "prod bump with a passing report should pass" unless
  gate_passes { |r| bump.(r, dev: "1.1.0", prod: "1.1.0"); write_report(r, "chat", "1.1.0") }

# 4. Prod bump whose report says verdict: fail -> refuse (a failing eval must not promote).
failures << "verdict: fail should cleanly refuse" unless
  gate_refuses { |r| bump.(r, dev: "1.1.0", prod: "1.1.0"); write_report(r, "chat", "1.1.0", verdict: "fail") }

# 5. Report whose version field contradicts its filename -> refuse (copy-paste from the last bump).
failures << "report version-field mismatch should cleanly refuse" unless
  gate_refuses { |r| bump.(r, dev: "1.1.0", prod: "1.1.0"); write_report(r, "chat", "1.1.0", version_field: "1.0.0") }

# 6. Dev-only bump -> no gate (promotion friction is prod-only).
failures << "dev-only bump should pass without a report" unless
  gate_passes { |r| bump.(r, dev: "2.0.0", prod: "1.0.0") }

# 7. Rollback: base is 1.1.0, tree returns to 1.0.0 whose report exists from its original
#    promotion -> pass with no new report (rollback speed never taxed, ADR-0007).
failures << "rollback to a previously-evaluated version should pass" unless
  gate_passes(base_prod: "1.1.0") { |r| bump.(r, dev: "1.0.0", prod: "1.0.0"); write_report(r, "chat", "1.0.0") }

# 8. The bump hides in defaults.units (inherited by prod) -> gates exactly like an explicit one.
failures << "defaults-inherited prod bump without a report should cleanly refuse" unless
  gate_refuses(prod_in_defaults: true) { |r| bump.(r, dev: "1.1.0", prod: "1.1.0", prod_in_defaults: true) }

# 9. New tenant appearing with a prod unit -> first prod deploy is a promotion, needs a report.
failures << "new prod tenant without a report should cleanly refuse" unless
  gate_refuses do |r|
    File.write(File.join(r, "tenants", "t2.yaml"),
               tenant_yaml(dev_version: "0.1.0", prod_version: "0.1.0").sub("slug: t1", "slug: t2"))
  end

if failures.empty?
  puts "eval-gate tests OK — 9 cases: refusals fire, no-ops/dev/rollbacks stay friction-free"
else
  failures.each { |f| warn "::error::#{f}" }
  exit 1
end
