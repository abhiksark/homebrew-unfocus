#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "digest"
require "erb"
require "json"
require "tempfile"
require "time"

module UnfocusCask
  EXPECTED_REPOSITORY = "abhiksark/unfocus"
  CHANNELS = %w[alpha beta].freeze

  class Error < StandardError
  end

  class SemVer
    include Comparable

    PATTERN = /\A(?<major>0|[1-9]\d*)\.(?<minor>0|[1-9]\d*)\.(?<patch>0|[1-9]\d*)(?:-(?<prerelease>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?\z/

    def self.parse(text)
      match = PATTERN.match(text)
      raise ArgumentError, "invalid semantic version: #{text}" unless match

      prerelease = match[:prerelease]&.split(".") || []
      if prerelease.any? { |identifier| identifier.match?(/\A\d+\z/) && identifier.length > 1 && identifier.start_with?("0") }
        raise ArgumentError, "numeric prerelease identifiers cannot have leading zeroes: #{text}"
      end

      new(match[:major].to_i, match[:minor].to_i, match[:patch].to_i, prerelease)
    end

    def initialize(major, minor, patch, prerelease)
      @major = major
      @minor = minor
      @patch = patch
      @prerelease = prerelease.freeze
    end

    def prerelease?
      !@prerelease.empty?
    end

    def channel_prerelease?(channel)
      @prerelease.length == 2 &&
        @prerelease.first == channel &&
        @prerelease.last.match?(/\A(?:0|[1-9]\d*)\z/)
    end

    def <=>(other)
      return nil unless other.is_a?(SemVer)

      core_order = [@major, @minor, @patch] <=> [other.major, other.minor, other.patch]
      return core_order unless core_order.zero?
      return 0 unless prerelease? || other.prerelease?
      return 1 unless prerelease?
      return(-1) unless other.prerelease?

      [@prerelease.length, other.prerelease.length].max.times do |index|
        left = @prerelease[index]
        right = other.prerelease[index]
        return(-1) if left.nil?
        return 1 if right.nil?

        left_numeric = left.match?(/\A\d+\z/)
        right_numeric = right.match?(/\A\d+\z/)
        order = if left_numeric && right_numeric
                  left.to_i <=> right.to_i
                elsif left_numeric
                  -1
                elsif right_numeric
                  1
                else
                  left <=> right
                end
        return order unless order.zero?
      end

      0
    end

    def to_s
      core = [@major, @minor, @patch].join(".")
      prerelease? ? "#{core}-#{@prerelease.join(".")}" : core
    end

    protected

    attr_reader :major, :minor, :patch, :prerelease
  end

  class Updater
    def initialize(options)
      @options = options
    end

    def run
      release = JSON.parse(File.read(@options.fetch(:release_json)))
      releases = JSON.parse(File.read(@options.fetch(:releases_json)))
      verified = ReleaseVerifier.new(@options, release, releases).verify
      version = verified.fetch(:version)
      tag_name = verified.fetch(:tag_name)
      arm_name = verified.fetch(:arm_name)
      intel_name = verified.fetch(:intel_name)
      arm_sha256 = verified.fetch(:arm_sha256)
      intel_sha256 = verified.fetch(:intel_sha256)
      rendered = ERB.new(File.read(@options.fetch(:template)), trim_mode: "-").result_with_hash(
        version: version.to_s,
        arm_sha256: arm_sha256,
        intel_sha256: intel_sha256
      )
      changed = reconcile_cask(@options.fetch(:output), rendered, version)

      metadata = {
        "changed" => changed,
        "channel" => @options.fetch(:channel),
        "version" => version.to_s,
        "tag_name" => tag_name,
        "release_id" => verified.fetch(:release_id),
        "release_url" => "https://github.com/#{EXPECTED_REPOSITORY}/releases/tag/#{tag_name}",
        "assets" => {
          "arm" => { "name" => arm_name, "sha256" => arm_sha256 },
          "intel" => { "name" => intel_name, "sha256" => intel_sha256 }
        }
      }
      write_atomic(@options.fetch(:metadata), "#{JSON.pretty_generate(metadata)}\n")
      metadata
    end

    private

    def reconcile_cask(path, rendered, version)
      unless File.exist?(path)
        write_atomic(path, rendered)
        return true
      end

      current = File.read(path)
      matches = current.scan(/^\s*version\s+"([^"]+)"\s*$/)
      raise Error, "existing cask must contain exactly one version" unless matches.length == 1

      current_version = SemVer.parse(matches.first.first)
      channel = @options.fetch(:channel)
      unless current_version.channel_prerelease?(channel)
        raise Error, "existing cask is not an exact #{channel} prerelease"
      end
      if current_version > version
        raise Error, "refusing to downgrade unfocus@#{channel} from #{current_version} to #{version}"
      end
      if current_version == version
        raise Error, "same-version cask differs from the verified release" unless current == rendered

        return false
      end

      write_atomic(path, rendered)
      true
    rescue ArgumentError => error
      raise Error, "existing cask has an invalid version: #{error.message}"
    end

    def write_atomic(path, contents)
      directory = File.dirname(path)
      basename = File.basename(path)
      temporary = Tempfile.new([".#{basename}.", ".tmp"], directory)
      temporary.binmode
      temporary.write(contents)
      temporary.flush
      temporary.fsync
      temporary.close
      File.rename(temporary.path, path)
    ensure
      temporary&.close!
    end
  end

  class ReleaseVerifier
    def initialize(options, release, releases)
      @options = options
      @release = release
      @releases = releases
    end

    def verify
      verify_identity
      version = verify_release_state
      verify_newest_release
      artifacts = verify_assets(version)

      {
        version: version,
        tag_name: @options.fetch(:tag_name),
        release_id: Integer(@options.fetch(:release_id), 10)
      }.merge(artifacts)
    rescue ArgumentError => error
      raise Error, error.message
    end

    private

    def verify_identity
      source_repository = @options.fetch(:source_repository)
      unless source_repository == EXPECTED_REPOSITORY
        raise Error, "unexpected source repository: #{source_repository}"
      end

      expected_id = Integer(@options.fetch(:release_id), 10)
      unless @release["id"] == expected_id
        raise Error, "release id does not match the dispatch payload"
      end

      expected_tag = @options.fetch(:tag_name)
      unless @release["tag_name"] == expected_tag
        raise Error, "release tag does not match the dispatch payload"
      end
    end

    def verify_release_state
      tag_name = @options.fetch(:tag_name)
      raise Error, "release tag must start with v" unless tag_name.start_with?("v")

      channel = @options.fetch(:channel)
      begin
        version = SemVer.parse(tag_name.delete_prefix("v"))
      rescue ArgumentError
        raise Error, "release tag must be an exact #{channel} prerelease (vX.Y.Z-#{channel}.N)"
      end
      unless version.channel_prerelease?(channel)
        raise Error, "release tag must be an exact #{channel} prerelease (vX.Y.Z-#{channel}.N)"
      end
      raise Error, "release is still a draft" unless @release["draft"] == false
      raise Error, "release is not a prerelease" unless @release["prerelease"] == true
      raise Error, "release is not immutable" unless @release["immutable"] == true

      published_at = @release["published_at"]
      raise Error, "release is not published" unless published_at.is_a?(String) && !published_at.empty?

      Time.iso8601(published_at)
      version
    end

    def verify_newest_release
      releases = normalize_release_pages(@releases)
      channel = @options.fetch(:channel)
      published_prereleases = releases.each_with_object([]) do |release, result|
        next unless release["draft"] == false && release["prerelease"] == true
        next unless release_channel_version(release)&.channel_prerelease?(channel)

        published_at = release["published_at"]
        raise Error, "a published prerelease has no publication timestamp" unless published_at.is_a?(String) && !published_at.empty?

        result << [Time.iso8601(published_at), release]
      end
      raise Error, "GitHub returned no published #{channel} prereleases" if published_prereleases.empty?

      newest_time = published_prereleases.map(&:first).max
      newest = published_prereleases.select { |published_at, _release| published_at == newest_time }.map(&:last)
      unless newest.length == 1 && newest.first["id"] == @release["id"] && newest.first["tag_name"] == @release["tag_name"]
        raise Error, "dispatch tag is not the newest published #{channel} prerelease"
      end
    end

    def release_channel_version(release)
      tag_name = release["tag_name"]
      return nil unless tag_name.is_a?(String) && tag_name.start_with?("v")

      SemVer.parse(tag_name.delete_prefix("v"))
    rescue ArgumentError
      nil
    end

    def normalize_release_pages(value)
      raise Error, "releases response must be an array" unless value.is_a?(Array)

      releases = value.flat_map { |entry| entry.is_a?(Array) ? entry : [entry] }
      raise Error, "releases response contains a malformed release" unless releases.all? { |release| release.is_a?(Hash) }

      releases
    end

    def verify_assets(version)
      arm_name = "Unfocus_#{version}_aarch64.dmg"
      intel_name = "Unfocus_#{version}_x64.dmg"
      assets = @release["assets"]
      raise Error, "release assets must be an array" unless assets.is_a?(Array)

      selected = [arm_name, intel_name, "SHA256SUMS"].to_h do |name|
        matches = assets.select { |asset| asset.is_a?(Hash) && asset["name"] == name }
        raise Error, "release must contain exactly one #{name}" unless matches.length == 1

        [name, matches.first]
      end

      actual_hashes = selected.to_h do |name, asset|
        raise Error, "release asset #{name} is not uploaded" unless asset["state"] == "uploaded"

        digest = asset["digest"]
        unless digest.is_a?(String) && digest.match?(/\Asha256:[0-9a-f]{64}\z/)
          raise Error, "release asset #{name} has a malformed GitHub digest"
        end

        path = File.join(@options.fetch(:assets_dir), name)
        raise Error, "downloaded asset is missing: #{name}" unless File.file?(path)

        actual = Digest::SHA256.file(path).hexdigest
        raise Error, "downloaded #{name} does not match its GitHub digest" unless digest == "sha256:#{actual}"

        [name, actual]
      end

      sums = parse_checksum_manifest(File.join(@options.fetch(:assets_dir), "SHA256SUMS"))
      [arm_name, intel_name].each do |name|
        unless sums[name] == actual_hashes.fetch(name)
          raise Error, "#{name} does not match SHA256SUMS"
        end
      end

      {
        arm_name: arm_name,
        intel_name: intel_name,
        arm_sha256: actual_hashes.fetch(arm_name),
        intel_sha256: actual_hashes.fetch(intel_name)
      }
    end

    def parse_checksum_manifest(path)
      entries = {}
      File.readlines(path, chomp: true).each do |line|
        match = /\A([0-9A-Fa-f]{64}) ([ *])(.+)\z/.match(line)
        raise Error, "malformed SHA256SUMS line: #{line}" unless match

        name = match[3]
        if File.basename(name) != name || name == "." || name == ".." || entries.key?(name)
          raise Error, "malformed SHA256SUMS entry: #{name}"
        end
        entries[name] = match[1].downcase
      end
      raise Error, "SHA256SUMS is empty" if entries.empty?

      entries
    end
  end

  def self.parse_options(arguments)
    options = {}
    parser = OptionParser.new do |definition|
      definition.banner = "Usage: update_cask.rb [options]"
      definition.on("--channel CHANNEL") { |value| options[:channel] = value }
      definition.on("--source-repository REPOSITORY") { |value| options[:source_repository] = value }
      definition.on("--release-id ID") { |value| options[:release_id] = value }
      definition.on("--tag-name TAG") { |value| options[:tag_name] = value }
      definition.on("--release-json PATH") { |value| options[:release_json] = value }
      definition.on("--releases-json PATH") { |value| options[:releases_json] = value }
      definition.on("--assets-dir PATH") { |value| options[:assets_dir] = value }
      definition.on("--template PATH") { |value| options[:template] = value }
      definition.on("--output PATH") { |value| options[:output] = value }
      definition.on("--metadata PATH") { |value| options[:metadata] = value }
    end
    parser.parse!(arguments)

    if options.key?(:channel) && !CHANNELS.include?(options[:channel])
      raise Error, "channel must be alpha or beta"
    end

    required = %i[channel source_repository release_id tag_name release_json releases_json assets_dir template output metadata]
    missing = required.reject { |name| options.key?(name) }
    raise Error, "missing required options: #{missing.join(", ")}" unless missing.empty?

    options
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    UnfocusCask::Updater.new(UnfocusCask.parse_options(ARGV)).run
  rescue UnfocusCask::Error, ArgumentError, JSON::ParserError, KeyError, Errno::ENOENT => error
    warn error.message
    exit 1
  end
end
