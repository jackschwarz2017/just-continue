# Building a signed and notarized release

The default build is a universal app containing Apple Silicon (`arm64`) and Intel (`x86_64`)
executables. Both require macOS 14 or later. A single ZIP can serve both kinds of Mac.

## 1. Set up your Apple signing identity

You need Apple Developer Program membership and full Xcode. In Xcode Settings, add your Apple
Account, select your team, open Manage Certificates, and create a **Developer ID Application**
certificate. The certificate and its private key must be installed in your Mac's keychain.
Apple also documents [creating the certificate in the developer portal](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/).

Find its exact name:

```sh
security find-identity -v -p codesigning
```

Use the entry beginning `Developer ID Application:` in step 3. Your Team ID is the identifier
shown in your developer account's membership details, usually also in parentheses in the
certificate name.

## 2. Store notarization credentials once

Create an app-specific password at [account.apple.com](https://account.apple.com/), under
Sign-In and Security. Then run:

```sh
xcrun notarytool store-credentials "just-continue-notary" \
  --apple-id "YOUR_APPLE_ACCOUNT_EMAIL" \
  --team-id "YOUR_TEAM_ID"
```

Enter the app-specific password at the secure prompt. The tool validates and saves the
credentials in Keychain. The password does not need to appear in a command or repository file.

## 3. Build and sign

Run from the repository root, substituting the identity from step 1. Use the version you intend
to release and increment the build number for later builds.

```sh
VERSION=0.1.0 BUILD=1 \
SIGN_IDENTITY="Developer ID Application: YOUR_NAME (YOUR_TEAM_ID)" \
scripts/build-app.sh
```

The script creates `build/Just Continue.app`, enables the hardened runtime, includes the
Apple Events entitlement for terminal automation, and signs with a secure timestamp.
Leave `DEBUG_MENU` unset for a release. For an Intel-only build, prefix the command with
`ARCHS=x86_64`; for Apple Silicon only, use `ARCHS=arm64`.

Verify the architecture and signature:

```sh
xcrun lipo -archs "build/Just Continue.app/Contents/MacOS/JustContinue"
codesign --verify --strict --verbose=2 "build/Just Continue.app"
codesign -dv --verbose=4 "build/Just Continue.app"
```

The universal binary should list `arm64` and `x86_64`. The signature details should show your
Developer ID authority, TeamIdentifier, timestamp, and the `runtime` flag.

## 4. Submit to Apple

Create a submission ZIP and send it to the notary service:

```sh
ditto -c -k --sequesterRsrc --keepParent \
  "build/Just Continue.app" "build/JustContinue-notarization.zip"
xcrun notarytool submit "build/JustContinue-notarization.zip" \
  --keychain-profile "just-continue-notary" --wait
```

Proceed when the status is **Accepted**. If it is Invalid, get the log using the submission ID
printed by the tool:

```sh
xcrun notarytool log "SUBMISSION_ID" \
  --keychain-profile "just-continue-notary" "build/notarization-log.json"
```

If processing is still in progress, use `xcrun notarytool wait "SUBMISSION_ID" --keychain-profile
"just-continue-notary"` rather than rebuilding or resubmitting.

## 5. Staple the ticket and verify

The ticket attaches to the app, so macOS can verify notarization offline:

```sh
xcrun stapler staple "build/Just Continue.app"
xcrun stapler validate "build/Just Continue.app"
codesign --verify --strict --verbose=2 "build/Just Continue.app"
spctl --assess --type execute --verbose=4 "build/Just Continue.app"
```

The assessment should say **accepted**, with **Notarized Developer ID** as its source.
Do not rebuild, re-sign, or modify the app after this step.

## 6. Package and test the download

Create a new ZIP from the stapled app. ZIP archives themselves cannot be stapled.

```sh
ditto -c -k --sequesterRsrc --keepParent \
  "build/Just Continue.app" "build/JustContinue-0.1.0-universal.zip"
shasum -a 256 "build/JustContinue-0.1.0-universal.zip"
```

Test the actual downloaded ZIP on an Apple Silicon Mac and an Intel Mac running macOS 14+,
preferably machines not used for development. Verify launch, terminal permissions, session
detection, and continuation. Cross-compiling confirms the binary can be built; it does not
replace testing on Intel hardware.

## 7. Publish on GitHub

Create a release in [the public repository](https://github.com/jackschwarz2017/just-continue/releases/new)
with a tag such as `v0.1.0` pointing to public `main`. Attach only
`JustContinue-0.1.0-universal.zip`, and optionally its checksum. Mention macOS 14+, support for
both Mac architectures, and the first-launch terminal permissions in the release notes.
The local `build` directory also contains private history backups and intermediate archives;
select the release ZIP explicitly.

Apple's references: [notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
and [notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
