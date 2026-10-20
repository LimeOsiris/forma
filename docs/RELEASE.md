# Building, signing and releasing

## Reproducible local build (no Apple Developer account needed)

```bash
scripts/build.sh
```

```bash
scripts/install.sh
```

Build variables: `CONFIG` (release or debug), `BUNDLE_ID` (default `app.forma.mac`; the extension's ID is `<BUNDLE_ID>.FinderSync`), `VERSION`, `BUILD`, `STAGE_DIR` and `SIGN_IDENTITY`. Without `SIGN_IDENTITY` the app is signed **ad-hoc** with the hardened runtime. It runs on the Mac that built it, but other Macs will block it.

## Developer ID distribution

You'll need an Apple Developer Program membership, a "Developer ID Application" certificate in your keychain, and a notarytool credential profile:

```bash
xcrun notarytool store-credentials forma-notary --apple-id you@example.com --team-id TEAMID
```

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=forma-notary VERSION=1.0.0 scripts/package.sh
```

That signs the extension and then the app with a timestamp and the hardened runtime, notarizes the zip, staples the ticket, and writes `dist/Forma-1.0.0.zip` and `dist/Forma-1.0.0.dmg`.

**Status: the shipped build is ad-hoc signed and not notarized.** The build machine had no signing identity, so signing and notarization are configured but have never been run.

## Entitlements

- App (`Resources/Forma.entitlements`): `com.apple.security.automation.apple-events`, which the hardened runtime needs to read Finder's selection. It isn't sandboxed because it writes next to your originals, uses Apple Events and optionally an event tap. That suits Developer ID distribution, not the Mac App Store.
- Finder extension: `com.apple.security.app-sandbox`, which Finder Sync extensions require.

## Universal binary

`swift build` with Command Line Tools builds for the host architecture. For a universal app, build `--triple x86_64-apple-macosx14.0` as well, `lipo -create` the two executables (and the extension built with `-target x86_64-apple-macos14.0`), then sign. Or build in Xcode.

## Versioning checklist

1. Bump `VERSION` and `BUILD`.
2. Run `swift run FormaTestRunner` (unit tests) and `.build/debug/Forma --ui-test <dir>` (UI checks). Both must pass.
3. Run `scripts/package.sh` with your identity and profile.
4. Check: `spctl -a -vv dist/…/Forma.app` and `xcrun stapler validate Forma.app`.
