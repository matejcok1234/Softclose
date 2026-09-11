# Shipping an update

Softclose updates itself through [Sparkle](https://sparkle-project.org). The app
checks a signed feed once a day, and there is a **Check for Updates…** item in
the menu bar.

## Back up the signing key. Today.

`appcast.sh` signs each release with an EdDSA private key that lives in your
login keychain. The matching public key is compiled into every copy of the app
that has ever been installed, and Sparkle refuses any update not signed by it.

**If that key is lost, no existing install can ever be updated again.** Not by
re-generating a key — a new key won't match the public one already out there.
Every user would have to find the download page and reinstall by hand, which is
exactly the situation Sparkle exists to avoid.

Export it now and keep it somewhere off this machine:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key.txt
```

That file is as sensitive as the Developer ID key in `~/Softclose-signing/`.
Anyone holding it can push an update to every Softclose install in the world.

To check which public key the tooling currently holds:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys -p
```

It must match `SUPublicEDKey` in `Info.plist`. If those two ever disagree,
updates will be signed with the wrong key and silently rejected by every client.

## Releasing

1. Bump `CFBundleShortVersionString` **and** `CFBundleVersion` in `Info.plist`.
   Sparkle compares `CFBundleVersion` to decide what is newer, so bumping only
   the display string ships an update nobody is offered.

2. ```bash
   ./release.sh          # builds, notarises, and regenerates docs/appcast.xml
   ```

3. Publish the DMG under a tag matching the version — the feed points at
   `releases/download/v<version>/Softclose-<version>.dmg`, so the tag has to be
   `v1.0.2` for version `1.0.2`:

   ```bash
   git tag -a v1.0.2 -m "Softclose 1.0.2" && git push origin v1.0.2
   gh release create v1.0.2 build/Softclose-1.0.2.dmg --title "Softclose 1.0.2" --notes "..."
   ```

4. Push `docs/appcast.xml`. It is served by GitHub Pages at
   <https://matejcok1234.github.io/Softclose/appcast.xml>, which is the URL
   compiled into the app as `SUFeedURL`.

   **That URL can never change** without shipping an update first — an app
   looking at a dead feed will never learn about a new one.

The feed lists only the newest version, which is all Sparkle needs.

## Checking it works

```bash
curl -s https://matejcok1234.github.io/Softclose/appcast.xml | head -20
```

Pages can take a minute or two to publish after a push. To prove the whole path
end to end, install an older version and use **Check for Updates…** — a feed
that parses is not proof that the download, the signature check and the
installer all work.
