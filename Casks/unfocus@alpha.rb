cask "unfocus@alpha" do
  arch arm: "aarch64", intel: "x64"

  version "0.4.0-alpha.1"
  sha256 arm:   "6777c7862187e809901c65bd75a54c01d6850a1bc2bbf1ccd2a6f92e130f3618",
         intel: "e003af6814a4b63dcb246121ee6f7fa67d57104e677a89f8ce235a5d60e2e5f0"

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
