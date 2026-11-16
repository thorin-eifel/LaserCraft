# Releasing LaserCraft

## 1. Universal app

```sh
./scripts/build_app.sh          # arm64 + x86_64 in one app (UNIVERSAL=0 for this Mac only)
lipo -archs build/LaserCraft.app/Contents/MacOS/LaserCraft      # -> x86_64 arm64
```

## 2. Disk image

```sh
./scripts/make_dmg.sh           # build/LaserCraft-<version>.dmg with an Applications shortcut
```

## 3. Signing and notarisation (so that Gatekeeper opens the app without right-click → Open)

This part needs a paid **Apple Developer Program** membership. It cannot be done without your own certificate and
Apple ID, so it is not part of the automatic build.

1. In Xcode → Settings → Accounts → Manage Certificates create a **Developer ID Application** certificate.
2. Create an app-specific password at appleid.apple.com and store the notary credentials once:
   ```sh
   xcrun notarytool store-credentials "lasercraft-notary" --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
   ```
3. Build, sign (hardened runtime + timestamp), pack and notarise:
   ```sh
   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build_app.sh
   ./scripts/make_dmg.sh
   NOTARY_PROFILE=lasercraft-notary ./scripts/notarize.sh build/LaserCraft-1.0.0-beta.6.dmg
   ```
   LaserCraft is not sandboxed. Serial ports, network connections, notifications and the power assertion work with the
   hardened runtime as they are; the camera window needs the entitlement `com.apple.security.device.camera`, which
   `build_app.sh` adds from `Resources/LaserCraft.entitlements` when you sign with a Developer ID.

## 3. Publish on GitHub

```sh
git tag -a v1.0.0-beta.6 -m "Release 1 Beta 6" && git push origin main v1.0.0-beta.6
gh release create v1.0.0-beta.6 --prerelease --title "Release 1 Beta 6" --notes-file notes.md \
   build/LaserCraft-1.0.0-beta.6.dmg
```

Version numbers: `LaserCraftVersion` in `Resources/Info.plist` (e.g. `1.0.0-beta.6`) is what people see and what the update
check compares with the GitHub release tags (`v1.0.0-beta.6`); `CFBundleShortVersionString` stays numeric (`1.0.0`) for macOS.
Pre-releases are only offered to people who run a pre-release themselves.

## 4. Updates

### Automatic updates with Sparkle (optional, needs your own key)

[Sparkle](https://sparkle-project.org) is built into the app (the framework is embedded by `build_app.sh`). It stays off until the
app's Info.plist contains your public update key, so the beta does not depend on anything that only you can provide:

1. `swift package resolve` downloads Sparkle and its tools to `.build/artifacts/sparkle/Sparkle/bin`.
2. Run `.build/artifacts/sparkle/Sparkle/bin/generate_keys` **once**. It stores the private key in your login keychain (back it up:
   without it nobody can ship updates to installed copies) and prints the public key.
3. Put the public key into `Resources/Info.plist` as `SUPublicEDKey`. `SUFeedURL` already points to
   `https://raw.githubusercontent.com/thorin-eifel/LaserCraft/main/appcast.xml`.
4. For every release put the `.dmg` (or `.zip`) into a folder and run `./scripts/make_appcast.sh <folder>`; it signs the files and
   writes `appcast.xml`, which you commit to the repository root.
5. Sign and notarise the app as above. Sparkle's helper programs are signed inside-out by `build_app.sh` when `CODESIGN_IDENTITY` is set.

With the key present, *Check for Updates…* and the automatic check use Sparkle; without it LaserCraft only looks for a newer release
on GitHub and points to its page. It was not possible to test a complete update here (no key, no hosted appcast).

LaserCraft checks the GitHub releases (at most once a day, switch off in *Settings → General → Updates*, or use
*LaserCraft → Check for Updates…*) and points to the release page. It never downloads or installs anything by itself.
For fully automatic updates the app would have to adopt [Sparkle](https://sparkle-project.org) with its own signing keys.

## 5. Homebrew cask (optional)

```ruby
cask "lasercraft" do
  version "1.0.0-beta.6"
  sha256 "<sha256 of the dmg>"
  url "https://github.com/thorin-eifel/LaserCraft/releases/download/v#{version}/LaserCraft-#{version}.dmg"
  name "LaserCraft"
  desc "Controller for Grbl laser engravers"
  homepage "https://github.com/thorin-eifel/LaserCraft"
  depends_on macos: ">= :sonoma"
  app "LaserCraft.app"
end
```
