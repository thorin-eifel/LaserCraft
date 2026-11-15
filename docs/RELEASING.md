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
   NOTARY_PROFILE=lasercraft-notary ./scripts/notarize.sh build/LaserCraft-1.0.0-beta.3.dmg
   ```
   LaserCraft is not sandboxed. Serial ports, network connections, notifications and the power assertion work with the
   hardened runtime as they are; the camera window needs the entitlement `com.apple.security.device.camera`, which
   `build_app.sh` adds from `Resources/LaserCraft.entitlements` when you sign with a Developer ID.

## 3. Publish on GitHub

```sh
git tag -a v1.0.0-beta.3 -m "Release 1 Beta 3" && git push origin main v1.0.0-beta.3
gh release create v1.0.0-beta.3 --prerelease --title "Release 1 Beta 3" --notes-file notes.md \
   build/LaserCraft-1.0.0-beta.3.dmg
```

Version numbers: `LaserCraftVersion` in `Resources/Info.plist` (e.g. `1.0.0-beta.3`) is what people see and what the update
check compares with the GitHub release tags (`v1.0.0-beta.3`); `CFBundleShortVersionString` stays numeric (`1.0.0`) for macOS.
Pre-releases are only offered to people who run a pre-release themselves.

## 4. Updates

LaserCraft checks the GitHub releases (at most once a day, switch off in *Settings → General → Updates*, or use
*LaserCraft → Check for Updates…*) and points to the release page. It never downloads or installs anything by itself.
For fully automatic updates the app would have to adopt [Sparkle](https://sparkle-project.org) with its own signing keys.

## 5. Homebrew cask (optional)

```ruby
cask "lasercraft" do
  version "1.0.0-beta.3"
  sha256 "<sha256 of the dmg>"
  url "https://github.com/thorin-eifel/LaserCraft/releases/download/v#{version}/LaserCraft-#{version}.dmg"
  name "LaserCraft"
  desc "Controller for Grbl laser engravers"
  homepage "https://github.com/thorin-eifel/LaserCraft"
  depends_on macos: ">= :sonoma"
  app "LaserCraft.app"
end
```
