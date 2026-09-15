cask "unfocus" do
  arch arm: "aarch64", intel: "x64"

  version "0.7.0"
  sha256 arm:   "19c8027fc04385e6f66c772ec5f1af5a7dedfb51353cf329d2f52b76e3c79f99",
         intel: "dc0d0e67ca9795bfde45e9784bea0a63f0ea9e3e09d158efc6737284bded4712"

  url "https://github.com/abhiksark/unfocus/releases/download/v#{version}/Unfocus_#{version}_#{arch}.dmg"
  name "Unfocus"
  desc "Local-first eye-break reminder"
  homepage "https://github.com/abhiksark/unfocus"

  livecheck do
    skip "Updates require a verified immutable release dispatch"
  end

  conflicts_with cask: ["unfocus@alpha", "unfocus@beta"]
  depends_on macos: :big_sur

  app "Unfocus.app"

  caveats <<~EOS
    This pre-1.x release is ad-hoc signed, not Developer ID-signed or notarized.
    macOS may block it at launch. Homebrew preserves Apple's quarantine metadata.
    Apple signing and notarization are deferred until 1.x.
    Review the first-launch instructions before opening the app:
      https://github.com/abhiksark/unfocus/blob/main/docs/install.md#first-launch-ad-hoc-signed--not-notarized
  EOS
end
