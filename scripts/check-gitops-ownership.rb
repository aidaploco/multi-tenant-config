#!/usr/bin/env ruby
# Ownership guard for the Config-Sync-synced gitops/ tree (ADR-0012 D12-3).
#
# Exactly one controller per object: Terraform owns tenant namespaces and their POLICY objects
# (via the tenant-namespace module); Config Sync owns the cluster-scoped baseline (gitops/cluster/)
# and the per-tenant APP PAYLOAD (gitops/payload/, rendered from the registry — ADR-0017).
# Two controllers managing the same object was a real bug: concrete tenant manifests used to live
# inside the synced tree, so Config Sync fought Terraform over them and would resurrect namespaces
# on offboard. This check makes the boundary a gate, not a convention.
require "yaml"

# Kinds only Terraform may manage. If one of these appears in the synced tree outside cluster/,
# some future PR is about to re-create the dual-ownership bug.
POLICY_KINDS = %w[
  Namespace NetworkPolicy ResourceQuota LimitRange
  Role RoleBinding ClusterRole ClusterRoleBinding ServiceAccount
].freeze

repo_root = File.expand_path(File.join(__dir__, ".."))
violations = []

# gitops/platform/ (ADR-0027) is renderer-generated platform-plane infra. NetworkPolicy and
# ServiceAccount are allowed there ONLY in platform-system: that namespace is Config Sync's
# turf (Terraform never manages objects in it — the monitoring netpols in cluster/ set the
# precedent), so no dual ownership is possible. The same kinds aimed at a TENANT namespace
# from the rendered tree would be the original bug again — still refused.
PLATFORM_KINDS = %w[NetworkPolicy ServiceAccount].freeze

Dir.glob(File.join(repo_root, "gitops", "**", "*.{yaml,yml}")).sort.each do |f|
  rel = f.sub("#{repo_root}/", "")
  next if rel.start_with?("gitops/cluster/") # the cluster-scoped baseline is Config Sync's turf

  YAML.load_stream(File.read(f)) do |doc|
    next unless doc.is_a?(Hash)

    kind = doc["kind"].to_s
    next unless POLICY_KINDS.include?(kind)

    if rel.start_with?("gitops/platform/") && PLATFORM_KINDS.include?(kind) &&
       doc.dig("metadata", "namespace") == "platform-system"
      next
    end

    violations << "#{rel}: kind #{kind} is Terraform-owned (tenant-namespace module) and must not be Config-Sync-synced"
  end
end

if violations.empty?
  puts "gitops ownership OK — no Terraform-owned policy kinds in the synced tree"
else
  violations.each { |v| warn "::error::#{v}" }
  exit 1
end
