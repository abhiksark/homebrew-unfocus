# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"
require_relative "update_cask"

class UpdateCaskCliTest < Minitest::Test
  SCRIPT = File.expand_path("update_cask.rb", __dir__)

  def test_help_describes_channel_and_release_inputs
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCRIPT, "--help")

    assert status.success?, stderr
    assert_includes stdout, "--channel"
    assert_includes stdout, "--source-repository"
    assert_includes stdout, "--release-json"
    assert_includes stdout, "--assets-dir"
  end

  def test_rejects_an_unsupported_channel
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCRIPT, "--channel", "stable")

    refute status.success?
    assert_includes stderr, "channel must be alpha or beta"
  end
end

class CaskCiWorkflowTest < Minitest::Test
  WORKFLOW = File.expand_path("../.github/workflows/cask-ci.yml", __dir__)

  def test_homebrew_audit_uses_the_read_only_job_token
    workflow = YAML.safe_load(File.read(WORKFLOW))
    style_steps = workflow.fetch("jobs").fetch("style").fetch("steps")
    audit_step = style_steps.find { |step| step["name"] == "Style and audit casks when present" }

    assert_equal "${{ github.token }}", audit_step.fetch("env", {})["HOMEBREW_GITHUB_API_TOKEN"]
  end
end

class UpdateWorkflowContractTest < Minitest::Test
  WORKFLOWS = {
    "alpha" => File.expand_path("../.github/workflows/update-alpha.yml", __dir__),
    "beta" => File.expand_path("../.github/workflows/update-beta.yml", __dir__)
  }.freeze
  SHARED_WORKFLOW = File.expand_path("../.github/workflows/update-channel.yml", __dir__)

  def test_channel_workflows_accept_only_the_guarded_source_dispatch
    WORKFLOWS.each do |channel, path|
      workflow = YAML.safe_load(File.read(path))

      assert_equal(
        { "repository_dispatch" => { "types" => ["unfocus-#{channel}-published"] } },
        workflow.fetch(true),
        channel
      )
      assert_equal(
        {
          "channel" => channel,
          "payload_release_id" => "${{ format('{0}', github.event.client_payload.release_id || '') }}",
          "payload_source_repository" => "${{ github.event.client_payload.source_repository || '' }}",
          "payload_tag" => "${{ github.event.client_payload.tag_name || '' }}"
        },
        workflow.fetch("jobs").fetch("update").fetch("with"),
        channel
      )
    end
  end

  def test_shared_workflow_has_no_manual_recovery_inputs
    workflow = YAML.safe_load(File.read(SHARED_WORKFLOW))
    inputs = workflow.fetch(true).fetch("workflow_call").fetch("inputs")

    assert_equal(
      %w[channel payload_release_id payload_source_repository payload_tag],
      inputs.keys.sort
    )
  end
end

class UpdateCaskIntegrationTest < Minitest::Test
  SCRIPT = File.expand_path("update_cask.rb", __dir__)
  SOURCE_REPOSITORY = "abhiksark/unfocus"
  TEMPLATES = {
    "alpha" => File.expand_path("../templates/unfocus@alpha.rb.erb", __dir__),
    "beta" => File.expand_path("../templates/unfocus@beta.rb.erb", __dir__)
  }.freeze
  EXPECTED_CASKS = {
    "alpha" => <<~RUBY,
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

        conflicts_with cask: "unfocus@beta"
        depends_on :macos

        app "Unfocus.app"

        caveats <<~EOS
          This alpha is not code-signed or notarized. macOS may block it at launch.
          Homebrew preserves Apple's quarantine metadata. This cask does not bypass
          Gatekeeper.
        EOS
      end
    RUBY
    "beta" => <<~RUBY
      cask "unfocus@beta" do
        arch arm: "aarch64", intel: "x64"

        version "0.1.0-beta.1"
        sha256 arm:   "8df572ae6ed716037eaf81fcb41147c1bf7c3f6f3826d53f91e12720273858bc",
               intel: "19f894fda737d93eea010da8697027181bad5b73035306361e75bdeb1b51701b"

        url "https://github.com/abhiksark/unfocus/releases/download/v\#{version}/Unfocus_\#{version}_\#{arch}.dmg"
        name "Unfocus"
        desc "Local-first eye-break reminder"
        homepage "https://github.com/abhiksark/unfocus"

        livecheck do
          skip "Updates require a verified immutable release dispatch"
        end

        conflicts_with cask: "unfocus@alpha"
        depends_on macos: :big_sur

        app "Unfocus.app"

        caveats <<~EOS
          This beta is not code-signed or notarized. macOS may block it at launch.
          Homebrew preserves Apple's quarantine metadata. This cask does not bypass
          Gatekeeper.
        EOS
      end
    RUBY
  }.freeze

  def test_generates_each_channel_cask_and_metadata_from_verified_release_artifacts
    each_channel do |channel|
      Dir.mktmpdir do |directory|
        fixture = write_release_fixture(directory, channel: channel)
        output = File.join(directory, "unfocus@#{channel}.rb")
        metadata = File.join(directory, "metadata.json")

        stdout, stderr, status = run_updater(
          fixture: fixture,
          output: output,
          metadata: metadata,
          channel: channel
        )

        assert status.success?, "#{channel}: #{stdout}\n#{stderr}"
        assert_equal EXPECTED_CASKS.fetch(channel), File.read(output)
        assert_equal expected_metadata(channel), JSON.parse(File.read(metadata))
      end
    end
  end

  def test_rejects_event_identity_mismatches_before_writing
    [
      ["different/project", 101, "v0.1.0-alpha.1", "unexpected source repository"],
      [SOURCE_REPOSITORY, 999, "v0.1.0-alpha.1", "release id does not match"],
      [SOURCE_REPOSITORY, 101, "v0.1.0-alpha.2", "release tag does not match"]
    ].each do |source_repository, release_id, tag_name, message|
      Dir.mktmpdir do |directory|
        fixture = write_release_fixture(directory, channel: "alpha")
        assert_rejected(
          fixture,
          "alpha",
          message,
          source_repository: source_repository,
          release_id: release_id,
          tag_name: tag_name
        )
      end
    end
  end

  def test_requires_an_exact_tag_for_the_selected_channel
    each_channel do |channel|
      other = channel == "alpha" ? "beta" : "alpha"
      ["v0.1.0-#{other}.1", "v0.1.0-#{channel}", "v0.1.0-#{channel}.01"].each do |tag_name|
        Dir.mktmpdir do |directory|
          fixture = write_release_fixture(directory, channel: channel)
          fixture.fetch(:release)["tag_name"] = tag_name
          rewrite_release_fixture(fixture)
          assert_rejected(fixture, channel, "exact #{channel} prerelease", tag_name: tag_name)
        end
      end
    end
  end

  def test_requires_a_published_immutable_prerelease_in_each_channel
    each_channel do |channel|
      [
        [{ "draft" => true }, "draft"],
        [{ "prerelease" => false }, "prerelease"],
        [{ "immutable" => false }, "immutable"],
        [{ "published_at" => nil }, "published"]
      ].each do |overrides, message|
        Dir.mktmpdir do |directory|
          fixture = write_release_fixture(directory, channel: channel, release_overrides: overrides)
          assert_rejected(fixture, channel, message)
        end
      end
    end
  end

  def test_rejects_a_release_that_is_not_newest_within_its_channel
    each_channel do |channel|
      Dir.mktmpdir do |directory|
        fixture = write_release_fixture(directory, channel: channel)
        newer = fixture.fetch(:release).merge(
          "id" => 102,
          "tag_name" => "v0.1.0-#{channel}.2",
          "published_at" => "2026-08-08T09:47:52Z"
        )
        File.write(fixture.fetch(:releases_json), JSON.generate([fixture.fetch(:release), newer]))

        assert_rejected(fixture, channel, "newest published #{channel} prerelease")
      end
    end
  end

  def test_ignores_a_newer_release_from_the_other_channel
    Dir.mktmpdir do |directory|
      fixture = write_release_fixture(directory, channel: "alpha")
      newer_beta = fixture.fetch(:release).merge(
        "id" => 102,
        "tag_name" => "v0.2.0-beta.1",
        "published_at" => "2026-08-08T09:47:52Z"
      )
      File.write(fixture.fetch(:releases_json), JSON.generate([fixture.fetch(:release), newer_beta]))
      output = File.join(directory, "unfocus@alpha.rb")

      _stdout, stderr, status = run_updater(
        fixture: fixture,
        output: output,
        metadata: File.join(directory, "metadata.json"),
        channel: "alpha"
      )

      assert status.success?, stderr
      assert_equal EXPECTED_CASKS.fetch("alpha"), File.read(output)
    end
  end

  def test_requires_exactly_one_expected_dmg_and_checksum_manifest
    each_channel do |channel|
      version = "0.1.0-#{channel}.1"
      [
        ["Unfocus_#{version}_aarch64.dmg", :delete],
        ["Unfocus_#{version}_x64.dmg", :duplicate],
        ["SHA256SUMS", :duplicate]
      ].each do |name, operation|
        Dir.mktmpdir do |directory|
          fixture = write_release_fixture(directory, channel: channel)
          assets = fixture.fetch(:release).fetch("assets")
          if operation == :delete
            assets.reject! { |asset| asset.fetch("name") == name }
          else
            assets << assets.find { |asset| asset.fetch("name") == name }.merge("id" => 99)
          end
          rewrite_release_fixture(fixture)

          assert_rejected(fixture, channel, "exactly one")
        end
      end
    end
  end

  def test_rejects_github_digest_mismatches_for_both_architectures_and_channels
    each_channel do |channel|
      %w[aarch64 x64].each do |architecture|
        Dir.mktmpdir do |directory|
          fixture = write_release_fixture(directory, channel: channel)
          asset = fixture.fetch(:release).fetch("assets").find do |candidate|
            candidate.fetch("name").end_with?("_#{architecture}.dmg")
          end
          asset["digest"] = "sha256:#{"0" * 64}"
          rewrite_release_fixture(fixture)

          assert_rejected(fixture, channel, "GitHub digest")
        end
      end
    end
  end

  def test_rejects_checksum_manifest_mismatches_in_each_channel
    each_channel do |channel|
      Dir.mktmpdir do |directory|
        fixture = write_release_fixture(directory, channel: channel)
        sums_path = File.join(fixture.fetch(:assets_dir), "SHA256SUMS")
        sums = File.read(sums_path).sub(/\A[0-9a-f]{64}/, "0" * 64)
        File.write(sums_path, sums)
        checksum_asset = fixture.fetch(:release).fetch("assets").find { |asset| asset.fetch("name") == "SHA256SUMS" }
        checksum_asset["digest"] = "sha256:#{Digest::SHA256.hexdigest(sums)}"
        rewrite_release_fixture(fixture)

        assert_rejected(fixture, channel, "SHA256SUMS")
      end
    end
  end

  def test_rejects_missing_downloads_and_malformed_checksum_manifests
    each_channel do |channel|
      Dir.mktmpdir do |directory|
        fixture = write_release_fixture(directory, channel: channel)
        File.delete(File.join(fixture.fetch(:assets_dir), "Unfocus_0.1.0-#{channel}.1_x64.dmg"))
        assert_rejected(fixture, channel, "downloaded asset is missing")
      end

      Dir.mktmpdir do |directory|
        fixture = write_release_fixture(directory, channel: channel)
        sums_path = File.join(fixture.fetch(:assets_dir), "SHA256SUMS")
        malformed = "#{File.read(sums_path)}not-a-checksum\n"
        File.write(sums_path, malformed)
        checksum_asset = fixture.fetch(:release).fetch("assets").find { |asset| asset.fetch("name") == "SHA256SUMS" }
        checksum_asset["digest"] = "sha256:#{Digest::SHA256.hexdigest(malformed)}"
        rewrite_release_fixture(fixture)
        assert_rejected(fixture, channel, "malformed SHA256SUMS")
      end
    end
  end

  def test_identical_redispatch_is_a_no_op_in_each_channel
    each_channel do |channel|
      Dir.mktmpdir do |directory|
        fixture = write_release_fixture(directory, channel: channel)
        output = File.join(directory, "unfocus@#{channel}.rb")
        _stdout, stderr, status = run_updater(
          fixture: fixture,
          output: output,
          metadata: File.join(directory, "first.json"),
          channel: channel
        )
        assert status.success?, stderr
        original_mtime = File.stat(output).mtime.to_r

        _stdout, stderr, status = run_updater(
          fixture: fixture,
          output: output,
          metadata: File.join(directory, "second.json"),
          channel: channel
        )

        assert status.success?, stderr
        assert_equal false, JSON.parse(File.read(File.join(directory, "second.json"))).fetch("changed")
        assert_equal original_mtime, File.stat(output).mtime.to_r
        assert_equal EXPECTED_CASKS.fetch(channel), File.read(output)
      end
    end
  end

  def test_rejects_same_version_checksum_changes_without_overwriting_each_cask
    each_channel do |channel|
      Dir.mktmpdir do |directory|
        fixture = write_release_fixture(directory, channel: channel)
        output = File.join(directory, "unfocus@#{channel}.rb")
        _stdout, stderr, status = run_updater(
          fixture: fixture,
          output: output,
          metadata: File.join(directory, "first.json"),
          channel: channel
        )
        assert status.success?, stderr

        version = "0.1.0-#{channel}.1"
        arm_name = "Unfocus_#{version}_aarch64.dmg"
        arm_path = File.join(fixture.fetch(:assets_dir), arm_name)
        File.binwrite(arm_path, "retagged-arm-dmg")
        arm_sha = Digest::SHA256.file(arm_path).hexdigest
        intel_name = "Unfocus_#{version}_x64.dmg"
        intel_sha = Digest::SHA256.file(File.join(fixture.fetch(:assets_dir), intel_name)).hexdigest
        sums = "#{arm_sha}  #{arm_name}\n#{intel_sha}  #{intel_name}\n"
        File.write(File.join(fixture.fetch(:assets_dir), "SHA256SUMS"), sums)
        assets = fixture.fetch(:release).fetch("assets")
        assets.find { |asset| asset.fetch("name") == arm_name }["digest"] = "sha256:#{arm_sha}"
        assets.find { |asset| asset.fetch("name") == "SHA256SUMS" }["digest"] = "sha256:#{Digest::SHA256.hexdigest(sums)}"
        rewrite_release_fixture(fixture)

        metadata = File.join(directory, "retagged.json")
        stdout, stderr, status = run_updater(
          fixture: fixture,
          output: output,
          metadata: metadata,
          channel: channel
        )

        refute status.success?, stdout
        assert_includes stderr, "same-version cask differs"
        assert_equal EXPECTED_CASKS.fetch(channel), File.read(output)
        refute File.exist?(metadata)
      end
    end
  end

  def test_rejects_downgrades_without_overwriting_each_cask
    each_channel do |channel|
      Dir.mktmpdir do |directory|
        fixture = write_release_fixture(directory, channel: channel)
        output = File.join(directory, "unfocus@#{channel}.rb")
        newer_cask = EXPECTED_CASKS.fetch(channel).sub(
          "version \"0.1.0-#{channel}.1\"",
          "version \"0.2.0-#{channel}.1\""
        )
        File.write(output, newer_cask)
        metadata = File.join(directory, "downgrade.json")

        stdout, stderr, status = run_updater(
          fixture: fixture,
          output: output,
          metadata: metadata,
          channel: channel
        )

        refute status.success?, stdout
        assert_includes stderr, "refusing to downgrade unfocus@#{channel}"
        assert_equal newer_cask, File.read(output)
        refute File.exist?(metadata)
      end
    end
  end

  def test_templates_and_generated_casks_do_not_bypass_gatekeeper
    forbidden = /no_quarantine|\bxattr\b|\bspctl\b|com\.apple\.quarantine|--master-disable/
    each_channel do |channel|
      template = TEMPLATES.fetch(channel)
      generated_cask = File.expand_path("../Casks/unfocus@#{channel}.rb", __dir__)

      refute_match forbidden, File.read(template)
      refute_match forbidden, File.read(generated_cask) if File.file?(generated_cask)
    end
  end

  private

  def each_channel(&block)
    %w[alpha beta].each(&block)
  end

  def expected_metadata(channel)
    version = "0.1.0-#{channel}.1"
    {
      "changed" => true,
      "channel" => channel,
      "version" => version,
      "tag_name" => "v#{version}",
      "release_id" => 101,
      "release_url" => "https://github.com/abhiksark/unfocus/releases/tag/v#{version}",
      "assets" => {
        "arm" => {
          "name" => "Unfocus_#{version}_aarch64.dmg",
          "sha256" => "8df572ae6ed716037eaf81fcb41147c1bf7c3f6f3826d53f91e12720273858bc"
        },
        "intel" => {
          "name" => "Unfocus_#{version}_x64.dmg",
          "sha256" => "19f894fda737d93eea010da8697027181bad5b73035306361e75bdeb1b51701b"
        }
      }
    }
  end

  def assert_rejected(fixture, channel, expected_message, **arguments)
    directory = File.dirname(fixture.fetch(:release_json))
    output = File.join(directory, "rejected.rb")
    metadata = File.join(directory, "rejected.json")
    stdout, stderr, status = run_updater(
      fixture: fixture,
      output: output,
      metadata: metadata,
      channel: channel,
      **arguments
    )

    refute status.success?, stdout
    assert_includes stderr, expected_message
    refute File.exist?(output), "the cask was written before validation failed"
    refute File.exist?(metadata), "metadata was written before validation failed"
  end

  def run_updater(
    fixture:,
    output:,
    metadata:,
    channel:,
    source_repository: SOURCE_REPOSITORY,
    release_id: 101,
    tag_name: nil
  )
    tag_name ||= "v0.1.0-#{channel}.1"
    Open3.capture3(
      RbConfig.ruby,
      SCRIPT,
      "--channel", channel,
      "--source-repository", source_repository,
      "--release-id", release_id.to_s,
      "--tag-name", tag_name,
      "--release-json", fixture.fetch(:release_json),
      "--releases-json", fixture.fetch(:releases_json),
      "--assets-dir", fixture.fetch(:assets_dir),
      "--template", TEMPLATES.fetch(channel),
      "--output", output,
      "--metadata", metadata
    )
  end

  def write_release_fixture(directory, channel:, release_overrides: {}, releases: nil)
    assets_dir = File.join(directory, "assets")
    FileUtils.mkdir_p(assets_dir)
    version = "0.1.0-#{channel}.1"
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

class UpdateCaskLibraryTest < Minitest::Test
  def test_parses_a_prerelease_version
    version = UnfocusCask::SemVer.parse("0.1.0-alpha.1")

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
      assert_raises(ArgumentError, text) { UnfocusCask::SemVer.parse(text) }
    end
  end

  def test_orders_versions_using_semantic_version_precedence
    alpha_one = UnfocusCask::SemVer.parse("0.1.0-alpha.1")
    assert_equal(-1, alpha_one <=> UnfocusCask::SemVer.parse("0.1.0-alpha.2"))

    assert_operator UnfocusCask::SemVer.parse("0.1.0-alpha.2"), :>, alpha_one
    assert_operator UnfocusCask::SemVer.parse("0.1.0-alpha.10"), :>, UnfocusCask::SemVer.parse("0.1.0-alpha.2")
    assert_operator UnfocusCask::SemVer.parse("0.1.0-alpha.beta"), :>, alpha_one
    assert_operator UnfocusCask::SemVer.parse("0.1.0"), :>, UnfocusCask::SemVer.parse("0.1.0-alpha.beta")
    assert_operator UnfocusCask::SemVer.parse("0.2.0-alpha.1"), :>, UnfocusCask::SemVer.parse("0.1.9")
  end
end
