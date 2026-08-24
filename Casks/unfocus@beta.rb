cask "unfocus@beta" do
  arch arm: "aarch64", intel: "x64"

  version "0.6.0-beta.1"
  sha256 arm:   "95fe23aaf958bf2341beddcbc64ff1f19088cc1ca47a48cbcc5b6e448af1b75e",
         intel: "c3d8a4a35bab06a26928b8947b65362c1ade51456d3677b3f714bb43f841f272"

  url "https://github.com/abhiksark/unfocus/releases/download/v#{version}/Unfocus_#{version}_#{arch}.dmg"
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
