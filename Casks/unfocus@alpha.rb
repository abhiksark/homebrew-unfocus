cask "unfocus@alpha" do
  arch arm: "aarch64", intel: "x64"

  version "0.2.0-alpha.1"
  sha256 arm:   "4f9ef1208e9cfd424d8c8817b110f6132969f0e0acbe481fb7917493988c6d01",
         intel: "d6e294fe310ececb1fc2cf10ecf4fbe226f819afc40e4d84db62c6d68e9004bd"

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
