# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"
require_relative "update_alpha"

class UpdateAlphaCliTest < Minitest::Test
  SCRIPT = File.expand_path("update_alpha.rb", __dir__)

  def test_help_describes_the_release_inputs
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCRIPT, "--help")

    assert status.success?, stderr
    assert_includes stdout, "--source-repository"
    assert_includes stdout, "--release-json"
    assert_includes stdout, "--assets-dir"
  end
end

class CaskCiWorkflowTest < Minitest::Test
  WORKFLOW = File.expand_path("../.github/workflows/cask-ci.yml", __dir__)

  def test_homebrew_audit_uses_the_read_only_job_token
    workflow = YAML.safe_load(File.read(WORKFLOW))
    style_steps = workflow.fetch("jobs").fetch("style").fetch("steps")
    audit_step = style_steps.find { |step| step["name"] == "Style and audit the cask when present" }

    assert_equal "${{ github.token }}", audit_step.fetch("env", {})["HOMEBREW_GITHUB_API_TOKEN"]
  end
end

class UpdateAlphaIntegrationTest < Minitest::Test
  SCRIPT = File.expand_path("update_alpha.rb", __dir__)
  TEMPLATE = File.expand_path("../templates/unfocus@alpha.rb.erb", __dir__)
  SOURCE_REPOSITORY = "abhiksark/unfocus"

  EXPECTED_CASK = <<~RUBY
    cask "unfocus@alpha" do
      arch arm: "aarch64", intel: "x64"

      version "0.1.0-alpha.1"
      sha256 arm:   "8df572ae6ed716037eaf81fcb41147c1bf7c3f6f3826d53f91e12720273858bc",
             intel: "19f894fda737d93eea010da8697027181bad5b73035306361e75bdeb1b51701b"

      url "https://github.com/abhiksark/unfocus/releases/download/v\#{version}/Unfocus_\#{version}_\#{arch}.dmg"
      name "Unfocus"
      desc "Local-first eye-break reminder"
      homepage "https://github.com/abhiksark/unfocus"

      livecheck do
        skip "Updates require a verified immutable release dispatch"
      end

      depends_on :macos

      app "Unfocus.app"

      caveats <<~EOS
        This alpha is not code-signed or notarized. macOS may block it at launch.
        Homebrew preserves Apple's quarantine metadata. This cask does not bypass
        Gatekeeper.
      EOS
    end
  RUBY

  def test_generates_the_cask_and_metadata_from_verified_release_artifacts
    Dir.mktmpdir do |directory|
      fixture = write_release_fixture(directory)
      output = File.join(directory, "unfocus@alpha.rb")
      metadata = File.join(directory, "metadata.json")

      stdout, stderr, status = run_updater(
        fixture: fixture,
        output: output,
        metadata: metadata
      )

      assert status.success?, "#{stdout}\n#{stderr}"
      assert_equal EXPECTED_CASK, File.read(output)
      assert_equal(
        {
          "changed" => true,
          "version" => "0.1.0-alpha.1",
          "tag_name" => "v0.1.0-alpha.1",
          "release_id" => 101,
          "release_url" => "https://github.com/abhiksark/unfocus/releases/tag/v0.1.0-alpha.1",
          "assets" => {
            "arm" => {
              "name" => "Unfocus_0.1.0-alpha.1_aarch64.dmg",
              "sha256" => "8df572ae6ed716037eaf81fcb41147c1bf7c3f6f3826d53f91e12720273858bc"
            },
            "intel" => {
              "name" => "Unfocus_0.1.0-alpha.1_x64.dmg",
              "sha256" => "19f894fda737d93eea010da8697027181bad5b73035306361e75bdeb1b51701b"
            }
          }
        },
        JSON.parse(File.read(metadata))
      )
    end
  end

  def test_rejects_event_identity_mismatches_before_writing
    [
      ["different/project", 101, "v0.1.0-alpha.1", "unexpected source repository"],
      [SOURCE_REPOSITORY, 999, "v0.1.0-alpha.1", "release id does not match"],
      [SOURCE_REPOSITORY, 101, "v0.1.0-alpha.2", "release tag does not match"]
    ].each do |source_repository, release_id, tag_name, message|
      Dir.mktmpdir do |directory|
        fixture = write_release_fixture(directory)
        assert_rejected(
          fixture,
          message,
          source_repository: source_repository,
          release_id: release_id,
          tag_name: tag_name
        )
      end
    end
  end

  def test_requires_a_published_immutable_prerelease
    [
      [{ "draft" => true }, "draft"],
      [{ "prerelease" => false }, "prerelease"],
      [{ "immutable" => false }, "immutable"],
      [{ "published_at" => nil }, "published"]
    ].each do |overrides, message|
      Dir.mktmpdir do |directory|
        fixture = write_release_fixture(directory, release_overrides: overrides)
        assert_rejected(fixture, message)
      end
    end
  end

  def test_rejects_a_prerelease_that_is_not_the_newest_published_prerelease
    Dir.mktmpdir do |directory|
      fixture = write_release_fixture(directory)
      newer = fixture.fetch(:release).merge(
        "id" => 102,
        "tag_name" => "v0.1.0-alpha.2",
        "published_at" => "2026-08-08T09:47:52Z"
      )
      File.write(fixture.fetch(:releases_json), JSON.generate([fixture.fetch(:release), newer]))

      assert_rejected(fixture, "newest published prerelease")
    end
  end

  def test_requires_exactly_one_expected_dmg_and_checksum_manifest
    [
      ["Unfocus_0.1.0-alpha.1_aarch64.dmg", :delete, "exactly one"],
      ["Unfocus_0.1.0-alpha.1_x64.dmg", :duplicate, "exactly one"],
      ["SHA256SUMS", :duplicate, "exactly one"]
    ].each do |name, operation, message|
      Dir.mktmpdir do |directory|
        fixture = write_release_fixture(directory)
        assets = fixture.fetch(:release).fetch("assets")
        if operation == :delete
          assets.reject! { |asset| asset.fetch("name") == name }
        else
          assets << assets.find { |asset| asset.fetch("name") == name }.merge("id" => 99)
        end
        rewrite_release_fixture(fixture)

        assert_rejected(fixture, message)
      end
    end
  end

  def test_rejects_github_digest_or_checksum_manifest_mismatches
    Dir.mktmpdir do |directory|
      fixture = write_release_fixture(directory)
      fixture.fetch(:release).fetch("assets").first["digest"] = "sha256:#{"0" * 64}"
      rewrite_release_fixture(fixture)
      assert_rejected(fixture, "GitHub digest")
    end

    Dir.mktmpdir do |directory|
      fixture = write_release_fixture(directory)
      sums_path = File.join(fixture.fetch(:assets_dir), "SHA256SUMS")
      sums = File.read(sums_path).sub(/\A[0-9a-f]{64}/, "0" * 64)
      File.write(sums_path, sums)
      checksum_asset = fixture.fetch(:release).fetch("assets").find { |asset| asset.fetch("name") == "SHA256SUMS" }
      checksum_asset["digest"] = "sha256:#{Digest::SHA256.hexdigest(sums)}"
      rewrite_release_fixture(fixture)
      assert_rejected(fixture, "SHA256SUMS")
    end

    Dir.mktmpdir do |directory|
      fixture = write_release_fixture(directory)
      checksum_asset = fixture.fetch(:release).fetch("assets").find { |asset| asset.fetch("name") == "SHA256SUMS" }
      checksum_asset["digest"] = "sha256:#{"f" * 64}"
      rewrite_release_fixture(fixture)
      assert_rejected(fixture, "GitHub digest")
    end
  end

  def test_rejects_missing_downloads_and_malformed_checksum_manifests
    Dir.mktmpdir do |directory|
      fixture = write_release_fixture(directory)
      File.delete(File.join(fixture.fetch(:assets_dir), "Unfocus_0.1.0-alpha.1_x64.dmg"))
      assert_rejected(fixture, "downloaded asset is missing")
    end

    Dir.mktmpdir do |directory|
      fixture = write_release_fixture(directory)
      sums_path = File.join(fixture.fetch(:assets_dir), "SHA256SUMS")
      original = File.read(sums_path)
      malformed = "#{original}not-a-checksum\n"
      File.write(sums_path, malformed)
      checksum_asset = fixture.fetch(:release).fetch("assets").find { |asset| asset.fetch("name") == "SHA256SUMS" }
      checksum_asset["digest"] = "sha256:#{Digest::SHA256.hexdigest(malformed)}"
      rewrite_release_fixture(fixture)
      assert_rejected(fixture, "malformed SHA256SUMS")
    end
  end

  def test_identical_redispatch_is_a_no_op
    Dir.mktmpdir do |directory|
      fixture = write_release_fixture(directory)
      output = File.join(directory, "unfocus@alpha.rb")
      first_metadata = File.join(directory, "first.json")
      _stdout, stderr, status = run_updater(fixture: fixture, output: output, metadata: first_metadata)
      assert status.success?, stderr
      original_mtime = File.stat(output).mtime.to_r

      second_metadata = File.join(directory, "second.json")
      _stdout, stderr, status = run_updater(fixture: fixture, output: output, metadata: second_metadata)

      assert status.success?, stderr
      assert_equal false, JSON.parse(File.read(second_metadata)).fetch("changed")
      assert_equal original_mtime, File.stat(output).mtime.to_r
      assert_equal EXPECTED_CASK, File.read(output)
    end
  end

  def test_rejects_same_version_checksum_changes_without_overwriting_the_cask
    Dir.mktmpdir do |directory|
      fixture = write_release_fixture(directory)
      output = File.join(directory, "unfocus@alpha.rb")
      first_metadata = File.join(directory, "first.json")
      _stdout, stderr, status = run_updater(fixture: fixture, output: output, metadata: first_metadata)
      assert status.success?, stderr

      arm_name = "Unfocus_0.1.0-alpha.1_aarch64.dmg"
      arm_path = File.join(fixture.fetch(:assets_dir), arm_name)
      File.binwrite(arm_path, "retagged-arm-dmg")
      arm_sha = Digest::SHA256.file(arm_path).hexdigest
      intel_name = "Unfocus_0.1.0-alpha.1_x64.dmg"
      intel_sha = Digest::SHA256.file(File.join(fixture.fetch(:assets_dir), intel_name)).hexdigest
      sums = "#{arm_sha}  #{arm_name}\n#{intel_sha}  #{intel_name}\n"
      File.write(File.join(fixture.fetch(:assets_dir), "SHA256SUMS"), sums)
      assets = fixture.fetch(:release).fetch("assets")
      assets.find { |asset| asset.fetch("name") == arm_name }["digest"] = "sha256:#{arm_sha}"
      assets.find { |asset| asset.fetch("name") == "SHA256SUMS" }["digest"] = "sha256:#{Digest::SHA256.hexdigest(sums)}"
      rewrite_release_fixture(fixture)

      metadata = File.join(directory, "retagged.json")
      stdout, stderr, status = run_updater(fixture: fixture, output: output, metadata: metadata)

      refute status.success?, stdout
      assert_includes stderr, "same-version cask differs"
      assert_equal EXPECTED_CASK, File.read(output)
      refute File.exist?(metadata)
    end
  end

  def test_rejects_downgrades_without_overwriting_the_cask
    Dir.mktmpdir do |directory|
      fixture = write_release_fixture(directory)
      output = File.join(directory, "unfocus@alpha.rb")
      newer_cask = EXPECTED_CASK.sub('version "0.1.0-alpha.1"', 'version "0.2.0-alpha.1"')
      File.write(output, newer_cask)
      metadata = File.join(directory, "downgrade.json")

      stdout, stderr, status = run_updater(fixture: fixture, output: output, metadata: metadata)

      refute status.success?, stdout
      assert_includes stderr, "refusing to downgrade"
      assert_equal newer_cask, File.read(output)
      refute File.exist?(metadata)
    end
  end

  def test_template_and_generated_cask_do_not_remove_quarantine_or_bypass_gatekeeper
    forbidden = /no_quarantine|\bxattr\b|\bspctl\b|com\.apple\.quarantine|--master-disable/
    generated_cask = File.expand_path("../Casks/unfocus@alpha.rb", __dir__)

    refute_match forbidden, File.read(TEMPLATE)
    refute_match forbidden, File.read(generated_cask) if File.file?(generated_cask)
  end

  private

  def assert_rejected(fixture, expected_message, **arguments)
    output = File.join(File.dirname(fixture.fetch(:release_json)), "rejected.rb")
    metadata = File.join(File.dirname(fixture.fetch(:release_json)), "rejected.json")
    stdout, stderr, status = run_updater(
      fixture: fixture,
      output: output,
      metadata: metadata,
      **arguments
    )

    refute status.success?, stdout
    assert_includes stderr, expected_message
    refute File.exist?(output), "the cask was written before validation failed"
    refute File.exist?(metadata), "metadata was written before validation failed"
  end

  def run_updater(fixture:, output:, metadata:, source_repository: SOURCE_REPOSITORY, release_id: 101, tag_name: "v0.1.0-alpha.1")
    Open3.capture3(
      RbConfig.ruby,
      SCRIPT,
      "--source-repository", source_repository,
      "--release-id", release_id.to_s,
      "--tag-name", tag_name,
      "--release-json", fixture.fetch(:release_json),
      "--releases-json", fixture.fetch(:releases_json),
      "--assets-dir", fixture.fetch(:assets_dir),
      "--template", TEMPLATE,
      "--output", output,
      "--metadata", metadata
    )
  end

  def write_release_fixture(directory, release_overrides: {}, releases: nil)
    assets_dir = File.join(directory, "assets")
    FileUtils.mkdir_p(assets_dir)
    version = "0.1.0-alpha.1"
    arm_name = "Unfocus_#{version}_aarch64.dmg"
    intel_name = "Unfocus_#{version}_x64.dmg"
    File.binwrite(File.join(assets_dir, arm_name), "arm-dmg")
    File.binwrite(File.join(assets_dir, intel_name), "intel-dmg")
    arm_sha = Digest::SHA256.file(File.join(assets_dir, arm_name)).hexdigest
    intel_sha = Digest::SHA256.file(File.join(assets_dir, intel_name)).hexdigest
    sums = "#{arm_sha}  #{arm_name}\n#{intel_sha}  #{intel_name}\n"
    File.write(File.join(assets_dir, "SHA256SUMS"), sums)

    release = {
      "id" => 101,
      "tag_name" => "v#{version}",
      "draft" => false,
      "prerelease" => true,
      "immutable" => true,
      "published_at" => "2026-08-07T09:47:52Z",
      "assets" => [
        asset(1, arm_name, arm_sha),
        asset(2, intel_name, intel_sha),
        asset(3, "SHA256SUMS", Digest::SHA256.hexdigest(sums))
      ]
    }.merge(release_overrides)

    release_json = File.join(directory, "release.json")
    releases_json = File.join(directory, "releases.json")
    File.write(release_json, JSON.generate(release))
    File.write(releases_json, JSON.generate(releases || [release]))

    {
      assets_dir: assets_dir,
      release: release,
      release_json: release_json,
      releases_json: releases_json
    }
  end

  def rewrite_release_fixture(fixture)
    File.write(fixture.fetch(:release_json), JSON.generate(fixture.fetch(:release)))
    File.write(fixture.fetch(:releases_json), JSON.generate([fixture.fetch(:release)]))
  end

  def asset(id, name, sha256)
    {
      "id" => id,
      "name" => name,
      "state" => "uploaded",
      "digest" => "sha256:#{sha256}"
    }
  end
end

class UpdateAlphaLibraryTest < Minitest::Test
  def test_parses_a_prerelease_version
    assert_respond_to UnfocusAlpha::SemVer, :parse

    version = UnfocusAlpha::SemVer.parse("0.1.0-alpha.1")

    assert_equal "0.1.0-alpha.1", version.to_s
    assert version.prerelease?
  end

  def test_rejects_malformed_or_unsupported_versions
    [
      "v0.1.0-alpha.1",
      "01.0.0-alpha",
      "1.0",
      "1.0.0-alpha..1",
      "1.0.0-alpha.01",
      "1.0.0-alpha+build"
    ].each do |text|
      assert_raises(ArgumentError, text) { UnfocusAlpha::SemVer.parse(text) }
    end
  end

  def test_orders_versions_using_semantic_version_precedence
    alpha_one = UnfocusAlpha::SemVer.parse("0.1.0-alpha.1")
    assert_equal(-1, alpha_one <=> UnfocusAlpha::SemVer.parse("0.1.0-alpha.2"))

    assert_operator UnfocusAlpha::SemVer.parse("0.1.0-alpha.2"), :>, alpha_one
    assert_operator UnfocusAlpha::SemVer.parse("0.1.0-alpha.10"), :>, UnfocusAlpha::SemVer.parse("0.1.0-alpha.2")
    assert_operator UnfocusAlpha::SemVer.parse("0.1.0-alpha.beta"), :>, alpha_one
    assert_operator UnfocusAlpha::SemVer.parse("0.1.0"), :>, UnfocusAlpha::SemVer.parse("0.1.0-alpha.beta")
    assert_operator UnfocusAlpha::SemVer.parse("0.2.0-alpha.1"), :>, UnfocusAlpha::SemVer.parse("0.1.9")
  end
end
