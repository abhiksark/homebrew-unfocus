cask "unfocus@alpha" do
  arch arm: "aarch64", intel: "x64"

  version "0.5.0-alpha.1"
  sha256 arm:   "2c1060793c390a1ba028f98a704c1e50b30341e389a86d4c710fe5619452d501",
         intel: "20f8ccc4d8f5e070b0ab1e52c4b792b958a4328f2b6bb73a3f0d713e81c151ab"

  url "https://github.com/abhiksark/unfocus/releases/download/v#{version}/Unfocus_#{version}_#{arch}.dmg"
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
