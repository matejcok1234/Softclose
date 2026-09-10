# Notarising a release

Without this, Gatekeeper rejects a downloaded copy outright — *"Softclose is
damaged and can't be opened"* — and every user has to strip the quarantine flag
by hand. With it, the DMG opens on a double-click.

Two of the steps need your Apple credentials, so they are yours to run. Once
they are done, `./release.sh` signs, notarises and staples on its own.

## 1. Create a Developer ID Application certificate

Needs a paid Apple Developer Program membership, and the Account Holder or Admin
role on the team.

**Xcode → Settings → Accounts →** select your team **→ Manage Certificates →**
the **+** button **→ Developer ID Application.**

It lands in your login keychain. Check it took:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

`build.sh` picks it up automatically from there — no edit needed. A team gets a
limited number of these (five), and they are painful to replace, so back the
certificate and its private key up: Keychain Access → right-click the identity →
Export, and keep the `.p12` somewhere safe.

## 2. Store notarisation credentials

Create an app-specific password at [appleid.apple.com](https://appleid.apple.com)
→ Sign-In and Security → App-Specific Passwords. It is not your Apple ID
password, and it is only usable for this.

```bash
xcrun notarytool store-credentials softclose \
    --apple-id you@example.com \
    --team-id YOURTEAMID \
    --password xxxx-xxxx-xxxx-xxxx
```

The team ID is the code in brackets after your name in the certificate list. The
password goes into your keychain under the profile name `softclose`, which is
what `release.sh` looks for — override it with `NOTARY_PROFILE` if you name it
something else.

## 3. Release

```bash
./release.sh
```

It signs with the Developer ID certificate, builds the DMG, submits it to Apple,
waits for the result, staples the ticket to the file, and prints Gatekeeper's
verdict on the finished DMG. That last line should say **accepted**.

## If notarisation is rejected

```bash
xcrun notarytool log <submission-id> --keychain-profile softclose
```

The usual causes: a missing secure timestamp (`--timestamp`, which `build.sh`
passes when signing with a Developer ID), or the hardened runtime not being
enabled (`--options runtime`, which it always passes).

## A side benefit

macOS ties Screen Recording permission to an app's signature. An ad-hoc
signature changes with every build, which is why `install.sh` has to reset the
approval each time — otherwise capture fails while the switch in Privacy
settings still reads as on. A Developer ID signature is stable across builds, so
the permission is granted once and then stays granted.
