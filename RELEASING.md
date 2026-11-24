# Releasing

Releases are automatic. Push a tag and GitHub Actions does the rest.

## Make a release

1. Merge the changes to `main`.
2. Tag the commit and push the tag:

   ```bash
   git tag v0.2.5 && git push origin v0.2.5
   ```

3. Watch the "Release" workflow in the Actions tab. It takes about 30 to 60 minutes.

The workflow builds the app, signs it with the Developer ID, notarizes and staples the dmg,
then publishes `BisprBlow.dmg` and `appcast.xml` as a GitHub release.
A second job then builds the Windows app and adds `BisprBlow-Windows.zip` to the same release.
Installed apps find the update through `appcast.xml` and install it when the user quits.

Contributors only open pull requests. Only people with write access can push a tag.

## Secrets

The workflow needs these repository secrets:

| Secret | What it is |
| --- | --- |
| `DEVID_P12_BASE64` | Developer ID Application certificate and key, as a base64 .p12 |
| `DEVID_P12_PASSWORD` | Password of that .p12 |
| `NOTARY_APPLE_ID` | Apple ID that notarizes |
| `NOTARY_TEAM_ID` | Apple team ID |
| `NOTARY_PASSWORD` | App-specific password for that Apple ID |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle EdDSA private key that signs the update feed |

The maintainer keeps a script that uploads them from the local signing folder.

To approve each release by hand, add required reviewers to the `release` environment
in the repository settings.

## Release from a Mac instead

With the Developer ID in the Keychain and a `bisprblow` notarytool profile:

```bash
./dmg.sh
gh release create v0.2.5 .build/BisprBlow.dmg .build/appcast.xml
```

## Windows

The `windows` job runs after the mac one and needs no secrets: `windows/package.ps1` builds a
self-contained zip (no models in it, the app fetches them on first run), `--self-check` must pass,
and the zip is attached to the release. It is unsigned, so SmartScreen warns on first run until
there is a code-signing certificate. The version comes from the tag (`v0.2.5` makes 0.2.5); an
untagged build keeps `<Version>` in `windows/BisprBlow.csproj`, so bump that with `Info.plist` when
the version moves.

From a Windows machine instead: `windows\package.ps1`, then
`gh release upload v0.2.5 .build\BisprBlow-Windows.zip`.
