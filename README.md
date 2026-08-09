# Homebrew tap for Unfocus

This tap distributes the current Unfocus prerelease as `unfocus@alpha`.
There is no stable `unfocus` cask yet.

## Install

```sh
brew install --cask abhiksark/unfocus/unfocus@alpha
```

These alpha builds are not code-signed or notarized. macOS Gatekeeper may
block the app at launch, and installing the cask does not establish the
publisher's identity. Homebrew preserves Apple's quarantine metadata; this
tap does not remove quarantine or bypass Gatekeeper. If you are not
comfortable reviewing that warning, wait for a signed and notarized release.

The cask downloads the matching disk image from the public
[Unfocus GitHub release](https://github.com/abhiksark/unfocus/releases) and
verifies its architecture-specific SHA-256 checksum. The upstream release
also publishes `SHA256SUMS` and GitHub build-provenance attestations for
independent verification.

## Upgrade

```sh
brew update
brew upgrade --cask abhiksark/unfocus/unfocus@alpha
```

## Uninstall

```sh
brew uninstall --cask abhiksark/unfocus/unfocus@alpha
```

The tap adds no updater or application runtime network behavior. A stable
`unfocus` cask will be considered only after signed and notarized artifacts
pass normal Gatekeeper launch; progress is tracked in
[Unfocus issue #26](https://github.com/abhiksark/unfocus/issues/26).
