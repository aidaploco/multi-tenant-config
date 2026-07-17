#!/usr/bin/env ruby
# NetworkPolicy shape guard for the Config-Sync-synced gitops/ tree (ADR-0023 follow-on;
# PLAN.md "Reference-platform review outcomes").
#
# Flags the ONE shape that is always a bug: a fully-empty ingress/egress rule (`ingress: [{}]`
# / `egress: [{}]` — no peers AND no ports), which permits everything from/to everywhere.
# NetworkPolicies are additive-permissive, so a single such rule silently disables every
# default-deny policy on the same pods.
#
# Why CI and not a Gatekeeper constraint: the admission layer (deny-tenant-netpol) already
# blocks everyone EXCEPT the platform applier — this guard covers the one writer admission
# deliberately trusts: us. At CI time no exemption list is needed, because nothing the
# platform legitimately ships has a fully-empty rule. (The reference platform this idea came
# from enforced a stricter shape check at admission and then punched namespace-sized
# exemptions through it for its own components — the exemption list became the hole. Scoping
# the check to the true allow-all shape is what makes zero exemptions possible.)
#
# Deliberately NOT flagged (platform design decisions, not bugs):
#   - rules with peers but no ports (e.g. allow-same-namespace: `from: [{podSelector: {}}]` —
#     the namespace IS the tenant boundary, all-pods-within-it is intended), and
#   - rules with ports but no peers (port-scoped, any peer),
#   - policies with policyTypes set and NO rule list at all (that's default-deny, the point).
require "yaml"

# A peer/port list "exists" only if it's a non-empty array. `from: []` behaves like a missing
# `from` in Kubernetes (matches everything) and must not count as scoping.
def present?(list)
  list.is_a?(Array) && !list.empty?
end

repo_root = File.expand_path(File.join(__dir__, ".."))
violations = []

Dir.glob(File.join(repo_root, "gitops", "**", "*.{yaml,yml}")).sort.each do |f|
  rel = f.sub("#{repo_root}/", "")

  YAML.load_stream(File.read(f)) do |doc|
    next unless doc.is_a?(Hash) && doc["kind"] == "NetworkPolicy"

    name = doc.dig("metadata", "name") || "<unnamed>"
    spec = doc["spec"] || {}

    { "ingress" => "from", "egress" => "to" }.each do |direction, peer_key|
      rules = spec[direction]
      next unless rules.is_a?(Array)

      rules.each_with_index do |rule, i|
        rule = {} if rule.nil? # `- {}` and a bare `-` both mean the empty rule
        next if present?(rule[peer_key]) || present?(rule["ports"])

        violations << "#{rel}: NetworkPolicy #{name}, #{direction} rule ##{i + 1} is fully " \
                      "empty (no #{peer_key}, no ports) — this allows ALL #{direction} and " \
                      "overrides every default-deny on the same pods (ADR-0023)"
      end
    end
  end
end

if violations.empty?
  puts "netpol shape OK — no fully-empty (allow-all) rules in the synced tree"
else
  violations.each { |v| warn "::error::#{v}" }
  exit 1
end
