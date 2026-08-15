cask "unfocus@alpha" do
  arch arm: "aarch64", intel: "x64"

  version "0.3.0-alpha.1"
  sha256 arm:   "1c4b2053e238139d5c02b397874d7b5a5bd303acfaf27305f8b02d8371db71e8",
         intel: "2ed6079e68a37bb1efded07b7b005e96db0d192ef2970e839b1fd66d425633eb"

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
