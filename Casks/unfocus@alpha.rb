cask "unfocus@alpha" do
  arch arm: "aarch64", intel: "x64"

  version "0.1.0-alpha.1"
  sha256 arm:   "20143180f90bbc65880c286c945023aba5e15fc449de6ce79efd00d9167d00bb",
         intel: "0165357ae1059aa079d759be717aa0d29e46909cfb9da76c79b99272a6aaed63"

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
