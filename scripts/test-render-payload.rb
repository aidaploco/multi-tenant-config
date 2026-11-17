#!/usr/bin/env ruby
# Golden-file tests for the payload renderer (ADR-0017 D17-1). Pure Ruby, runs in CI's guards
# job. The golden tree IS the reviewed contract: if a renderer change alters output, the test
# fails until the golden files are re-blessed in the same PR — output changes are always a
# visible, reviewed diff, never an accident.
#
# To re-bless after an INTENTIONAL output change:
#   ruby scripts/render-payload.rb --tenants-dir scripts/testdata/render-payload/tenants \
#     --out-dir scripts/testdata/render-payload/golden \
#     --platform-dir scripts/testdata/render-payload/golden-platform \
#     --registries scripts/testdata/render-payload/registries.yaml
require "tmpdir"

RENDERER = File.join(__dir__, "render-payload.rb")
TESTDATA = File.join(__dir__, "testdata", "render-payload")
failures = []

# 1. Golden: the fixture registry renders byte-identically to the blessed trees (payload AND
# the ADR-0027 platform tree). The fixture covers: env version override, defaults inheritance,
# image: override, opt_in false skip, unbuilt-archetype skip, per-tenant Phoenix, and a
# per-environment image registry (testdata/render-payload/registries.yaml: prod uses a path host).
Dir.mktmpdir do |tmp|
  out = File.join(tmp, "payload")
  platform = File.join(tmp, "platform")
  ok = system("ruby", RENDERER, "--tenants-dir", File.join(TESTDATA, "tenants"), "--out-dir", out,
              "--platform-dir", platform,
              "--registries", File.join(TESTDATA, "registries.yaml"), out: File::NULL)
  failures << "golden: renderer exited nonzero on the fixture registry" unless ok
  unless system("diff", "-ruN", File.join(TESTDATA, "golden"), out)
    failures << "golden: output differs from scripts/testdata/render-payload/golden/ (re-bless if intentional — see header)"
  end
  unless system("diff", "-ruN", File.join(TESTDATA, "golden-platform"), platform)
    failures << "golden: platform tree differs from scripts/testdata/render-payload/golden-platform/ (re-bless if intentional — see header)"
  end
end

# 2. Locale: a registry with real UTF-8 (an em dash) flowing through manifest_ref/packs_ref's
# File.read + YAML.dump round-trip must render under a non-UTF-8 locale, not just the CI
# runner's default one. Only this code path can reproduce it — YAML.load_file (the plain
# tenant-registry read) never mistags encoding, so a fixture without manifest_ref/packs_ref
# would pass even with the bug present.
Dir.mktmpdir do |tmp|
  env = { "LANG" => "C", "LC_ALL" => "C" }
  ok = system(env, "ruby", RENDERER,
              "--tenants-dir", File.join(TESTDATA, "locale-utf8", "tenants"),
              "--config-dir", File.join(TESTDATA, "locale-utf8", "config"),
              "--out-dir", File.join(tmp, "payload"),
              "--platform-dir", File.join(tmp, "platform"), out: File::NULL, err: File::NULL)
  failures << "locale: renderer crashed under LANG=C on UTF-8 content (regression)" unless ok
end

# 3. Guards: registries that MUST refuse to render (exit nonzero, quietly checked).
{ "bad-missing-version" => "opted-in agent-unit without a version",
  "bad-restricted"      => "restricted tenant with an agent-unit (shared-plane refusal)" }.each do |dir, what|
  Dir.mktmpdir do |tmp|
    ok = system("ruby", RENDERER, "--tenants-dir", File.join(TESTDATA, dir),
                "--out-dir", File.join(tmp, "payload"),
                "--platform-dir", File.join(tmp, "platform"), err: File::NULL)
    failures << "guard: #{what} should fail the render but succeeded" if ok
  end
end

# 3b. Guard: an env missing from image-registries.yaml, or a malformed host, must refuse to render.
{ "missing-env" => "dev: localhost:5001\n", "scheme" => "dev: https://x.io\nprod: x.io\nacc: x.io\n" }.each do |what, body|
  Dir.mktmpdir do |tmp|
    f = File.join(tmp, "registries.yaml")
    File.write(f, body)
    ok = system("ruby", RENDERER, "--tenants-dir", File.join(TESTDATA, "tenants"), "--registries", f,
                "--out-dir", File.join(tmp, "payload"), "--platform-dir", File.join(tmp, "platform"),
                out: File::NULL, err: File::NULL)
    failures << "guard: registries file (#{what}) should fail the render but succeeded" if ok
  end
end

# 4. Offboarding (ADR-0026 D26-1): a tenant with `offboarding: true` — otherwise identical to a
# rendering tenant — must produce an EMPTY tree. This empty render is the payload prune the
# offboard pipeline depends on; if it ever renders anything, the prune-before-destroy ordering
# is broken at the source.
Dir.mktmpdir do |tmp|
  out = File.join(tmp, "payload")
  platform = File.join(tmp, "platform")
  ok = system("ruby", RENDERER, "--tenants-dir", File.join(TESTDATA, "offboarding"),
              "--out-dir", out, "--platform-dir", platform, out: File::NULL)
  failures << "offboarding: renderer exited nonzero on the offboarding fixture" unless ok
  leftovers = Dir.glob([File.join(out, "**", "*"), File.join(platform, "**", "*")])
                 .select { |p| File.file?(p) }
  unless leftovers.empty?
    failures << "offboarding: tenant with offboarding: true still rendered payload/platform: #{leftovers.join(", ")}"
  end
end

if failures.empty?
  puts "render-payload tests OK — golden tree matches, locale-safe, refusal guards fire, offboarding renders empty"
else
  failures.each { |f| warn "::error::#{f}" }
  exit 1
end
