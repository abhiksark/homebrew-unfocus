cask "unfocus@beta" do
  arch arm: "aarch64", intel: "x64"

  version "0.6.0-beta.2"
  sha256 arm:   "6b4e4c92b8d32e07bf4748e95d5013bb70893184cfbabf2d2c961e6fe8f0440e",
         intel: "a93c7b5be343695a3f5cd187c27ae636499ac475b846edc7fbb5ced12163fdea"

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
