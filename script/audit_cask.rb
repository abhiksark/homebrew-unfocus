# frozen_string_literal: true

require_relative "update_cask"

module UnfocusAudit
  def self.arguments(channel, version)
    raise ArgumentError, "unsupported channel" unless UnfocusCask::CHANNELS.include?(channel)

    parsed = UnfocusCask::SemVer.parse(version)
    raise ArgumentError, "stable cask must use a stable version" if channel == "stable" && parsed.prerelease?

    # This maintainer-owned tap does not use homebrew/cask popularity admission.
    # Keep archived-repository and artifact audits; 1.x still requires signing.
    args = ["audit", "--new", "--cask"]
    if channel != "stable"
      args += ["--except", "signing,github_prerelease_version,github_repository"]
    elsif version.start_with?("0.")
      args += ["--except", "signing,github_repository"]
    else
      args += ["--except", "github_repository"]
    end
    args + ["abhiksark/unfocus/#{channel == 'stable' ? 'unfocus' : "unfocus@#{channel}"}"]
  end
end

if $PROGRAM_NAME == __FILE__
  channel, path = ARGV
  versions = File.read(path).scan(/^\s*version\s+"([^"]+)"/).flatten
  abort("expected one cask version") unless versions.length == 1
  exec("brew", *UnfocusAudit.arguments(channel, versions.first))
end
