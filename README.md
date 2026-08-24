# Homebrew tap for Unfocus

This tap distributes Unfocus prereleases through explicit channels. New
prereleases use `unfocus@beta`; `unfocus@alpha` remains frozen at
`0.5.0-alpha.1` for existing users. There is no stable `unfocus` cask yet.

The `@beta` token follows Homebrew's
[alternative release channel convention](https://docs.brew.sh/Acceptable-Casks#default-and-alternative-release-channels).

## Install beta

```sh
brew install --cask abhiksark/unfocus/unfocus@beta
```

The beta cask requires macOS 11 Big Sur or later.

## Move from alpha to beta

Migration is explicit. Uninstalling without `--zap` preserves Unfocus's local
application data:

```sh
brew uninstall --cask abhiksark/unfocus/unfocus@alpha
brew install --cask abhiksark/unfocus/unfocus@beta
```

The two casks conflict because both install `Unfocus.app`, so they cannot be
installed simultaneously. Users who do not migrate remain on the frozen alpha
cask.

## Security model

These prerelease builds are not code-signed or notarized. macOS Gatekeeper may
block the app at launch, and installing a cask does not establish the
publisher's identity. Homebrew preserves Apple's quarantine metadata; this tap
does not remove quarantine or bypass Gatekeeper. If you are not comfortable
reviewing that warning, wait for a signed and notarized release.

Each cask downloads the matching disk image from the public
[Unfocus GitHub release](https://github.com/abhiksark/unfocus/releases) and
verifies its architecture-specific SHA-256 checksum. The upstream release also
publishes `SHA256SUMS` and GitHub build-provenance attestations for independent
verification.

## Upgrade beta

```sh
brew update
brew upgrade --cask abhiksark/unfocus/unfocus@beta
```

## Uninstall

```sh
brew uninstall --cask abhiksark/unfocus/unfocus@beta
```

The tap adds no updater or application runtime network behavior. A stable
`unfocus` cask will be considered only after signed and notarized artifacts
pass normal Gatekeeper launch; progress is tracked in
[Unfocus issue #26](https://github.com/abhiksark/unfocus/issues/26).

## Automation

Published alpha and beta releases dispatch separate events. The shared updater
accepts only exact `vX.Y.Z-<channel>.N` tags, requires a published immutable
prerelease, selects the newest published release within that channel, verifies
both architecture digests and `SHA256SUMS`, and opens a reviewable automation
pull request. The beta cask is generated only after the first beta release is
published. First publish and recovery runs must start from the guarded
`Dispatch Homebrew alpha update` or `Dispatch Homebrew beta update` workflow
in `abhiksark/unfocus`; the tap does not accept direct manual update runs.
Redispatching an identical verified release recovers an interrupted update
idempotently.
