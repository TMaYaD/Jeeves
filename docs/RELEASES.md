# Releases

How Jeeves versions and tags builds. Distribution channel wiring (Firebase App Distribution groups, Play Store tracks) is **not** covered here yet — see follow-up work.

## Versioning model

A build's `versionName` is `<target>-<stage>.<N>`, or `<target>` for a GA build. `versionCode` is `github.run_number` — globally monotonic across all CI runs, decoupled from the version name.

- **target**: the SemVer target version (e.g. `1.3.0`).
- **stage**: one of `alpha`, `beta`, `rc`, or absent (GA).
- **N**: a counter that **resets at each stage boundary**.

| stage | when | N counts |
|---|---|---|
| `alpha` | no stage tag in HEAD's ancestry | commits since the last GA tag |
| `beta` | `v<target>-beta` is HEAD's most recent stage tag | commits since that tag, +1 (tagged commit is `.1`) |
| `rc` | `v<target>-rc` is HEAD's most recent stage tag | commits since that tag, +1 |
| GA | HEAD is at a `v<target>` tag | n/a — emit `<target>` verbatim |

Example timeline starting from `v1.2.0`:

```
v1.2.0                    1.2.0          (GA)
  + commit                1.3.0-alpha.1
  + commit                1.3.0-alpha.2
  ...
  + commit                1.3.0-alpha.17
v1.3.0-beta tagged here   1.3.0-beta.1
  + commit                1.3.0-beta.2
  + commit                1.3.0-beta.3
v1.3.0-rc tagged here     1.3.0-rc.1
  + commit                1.3.0-rc.2
v1.3.0 tagged here        1.3.0          (GA)
  + commit                1.4.0-alpha.1
```

## Tagging conventions

Stage tags are **unnumbered transition markers**. The tag itself is not the name of any artifact — the first artifact under the new stage is `<target>-<stage>.1`.

- **`v<target>`** — GA. Cuts a `<target>` build, published to GitHub Releases (non-prerelease). Play Store distribution comes through this tag.
- **`v<target>-beta`** — opens the beta window for `<target>`. First build is `<target>-beta.1`.
- **`v<target>-rc`** — opens the rc window. First build is `<target>-rc.1`.
- **`v<target>-alpha`** — **never tagged**. Alphas are computed automatically off `main`.

Numbered pre-release tags (`v1.3.0-beta.5`, etc.) don't trigger CI under the new tag patterns and should not be created by hand.

## Target version bumps mid-cycle

The target version is recomputed on every CI run from conventional commits since the last GA tag (`feat!:`/`BREAKING CHANGE:` → major, `feat:` → minor, else patch).

If the computed target exceeds the target declared by the current stage tag — for example, `v1.3.0-beta` is the active marker but a `feat!:` lands afterward — CI **auto-retags** HEAD with `v<new_target>-<same_stage>` (e.g. `v2.0.0-beta`) and emits the current build as `<new_target>-<stage>.1`. The retag tag is pushed by `github-actions[bot]` and is idempotent.

Rationale: stay SemVer-honest at GA. A 1.3.0-beta cycle that secretly contains breaking changes would ship a 1.3.0 GA that violates the contract. Auto-retag forces the version to track reality, even if the human-readable tag history shows the moment of regret (both `v1.3.0-beta` and `v2.0.0-beta` will exist as fossils).

The retag does not re-trigger the workflow (GitHub's `GITHUB_TOKEN`-authored tag pushes don't fan out to other workflow runs). The current run's emitted version anticipates the retag (N=1) so it matches what subsequent runs will compute.

## Release-branch policy

Currently: **trunk-only.** Features may merge between `v<target>-beta` and `v<target>` GA, and ride along in subsequent beta/rc builds. Beta testers should expect rolling builds, not feature-frozen ones.

This is acceptable at single-contributor scale. Switch to a release branch (`release/<target>`) when feature merges during beta cycles start producing tester confusion or when the team grows past 1–2 contributors. Until then, the dual-merge tax of release branches isn't worth paying.

## What this means for the workflow

- `.github/workflows/cd-app.yml` is the source of truth. The `version` job computes `version` and `pubspec_version`; downstream build/publish jobs stamp those into `pubspec.yaml` and produce APK/AAB/web artifacts.
- The workflow triggers on `workflow_run` of `Flutter CI` on `main` (alpha builds) and on `push` of GA / stage tags (release builds).
- GitHub Releases are created only when HEAD carries a GA or stage tag. Mid-stage builds (alphas, post-tag betas/rcs) produce artifacts but no Release entry.

## Firebase App Distribution channels

Channels are tester groups in Firebase App Distribution, named for the audience they serve:

| Channel | Audience | Source build | Tester expectation |
|---|---|---|---|
| `dev` | Internal engineering / PM / testers in the trenches | every PR (`pr-apk.yml`) | may be outright broken; fresh install every time |
| `canary` | Internal users tolerating breakage (the bagel-bringers) | every `main` commit (`cd-app.yml`) | mostly stable, occasional regressions |
| `beta` | External focus groups, investors, C-suites | `v<target>-beta` tag onward | stable enough to demo |
| `rc` | FOMO early adopters who want latest-and-greatest | `v<target>-rc` tag onward | believed shippable |

Each stage's build fans out to its own channel **and every less-restrictive one**. Internal testers (canary) see every build; investors (beta) skip alphas; FOMO adopters (rc) skip alphas and betas:

| Build | dev | canary | beta | rc |
|---|---|---|---|---|
| PR (`pr-apk.yml`) | ✓ | | | |
| `main` commit, alpha stage | | ✓ | | |
| beta-stage build | | ✓ | ✓ | |
| rc-stage build | | ✓ | ✓ | ✓ |
| GA tag | | ✓ | ✓ | ✓ |

The fan-out is driven by `firebase_groups` computed in the version job and passed to the `wzieba/Firebase-Distribution-Github-Action` step.

### Firebase project setup

Two Android apps must exist in the Firebase project:

- **Dev app** — applicationId `loonyb.in.jeeves.dev` (PR/dev-flavor builds). Configured via secret `FIREBASE_APP_ID_DEV`.
- **Production app** — applicationId `loonyb.in.jeeves` (production-flavor builds across canary/beta/rc/GA). Configured via secret `FIREBASE_APP_ID_PROD`.

Tester groups (`dev`, `canary`, `beta`, `rc`) are created in the Firebase console under each app's distribution settings. Both apps share `FIREBASE_SERVICE_ACCOUNT_JSON` (one service account, one Firebase project, two apps).

## Android signing

Every distributable Android artifact is signed with a stable, project-owned keystore so installs upgrade in place across CI runs and Play Store uploads are feasible. There are two keys, not one:

- **release key** — signs the production-flavor APK + AAB and the Seeker variant APK. This is the key end users get; rotating it forces every installed user to uninstall and reinstall.
- **dev key** — signs the dev-flavor (PR/canary engineering) APKs distributed via `pr-apk.yml`. The dev and production flavors already have distinct `applicationId`s (`loonyb.in.jeeves.dev` vs `loonyb.in.jeeves`) so they install side-by-side; the separate key purely limits blast radius — a leaked dev key (more exposure: every PR build) doesn't endanger production users.

### GitHub Actions secrets

| Secret | Used by | Purpose |
|---|---|---|
| `ANDROID_RELEASE_KEYSTORE_BASE64` | `cd-app.yml` (build-android, build-seeker) | base64-encoded `.jks` for production signing |
| `ANDROID_RELEASE_KEYSTORE_PASSWORD` | `cd-app.yml` | store password |
| `ANDROID_RELEASE_KEY_ALIAS` | `cd-app.yml` | alias inside the store |
| `ANDROID_RELEASE_KEY_PASSWORD` | `cd-app.yml` | key password |
| `ANDROID_DEV_KEYSTORE_BASE64` | `pr-apk.yml` | base64-encoded `.jks` for dev-flavor PR builds |
| `ANDROID_DEV_KEYSTORE_PASSWORD` | `pr-apk.yml` | store password |
| `ANDROID_DEV_KEY_ALIAS` | `pr-apk.yml` | alias inside the store |
| `ANDROID_DEV_KEY_PASSWORD` | `pr-apk.yml` | key password |

The `.github/actions/setup-android-signing` composite action decodes whichever secrets are populated and writes `app/android/key.properties` before the Flutter build runs. `cd-app.yml` passes `require-release: 'true'` so a missing release secret fails the job rather than silently shipping a debug-signed artifact. `pr-apk.yml` does not set `require-release` — if the dev secret is unset, PR builds fall back to debug signing with a warning.

### Where the keystores live

The two `.jks` files are kept outside the repo (the `app/android/` `.gitignore` blocks `*.jks` and `key.properties`). Canonical backups belong in the team's shared secret store alongside the Firebase service account JSON. Keep at least two copies in independent locations — losing the release key means the user-facing app can never be upgraded again, only re-published under a new package name.

Record the SHA-256 fingerprint of each canonical key in this doc once generated so a future build's `apksigner verify --print-certs` output can be sanity-checked against the known-good value:

- **release key SHA-256:** _record once generated_
- **dev key SHA-256:** _record once generated_

### Generating a new keystore

Use a long validity (Play Store requires the upload key to be valid past 2033, so pick ≥25 years):

```bash
keytool -genkeypair -v \
  -keystore keystore-release.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias jeeves-release
```

Repeat with `keystore-dev.jks` / `-alias jeeves-dev` for the dev key.

Encode the keystore for the GitHub secret. The value must be a single line, otherwise the GitHub secret stores the wrapped form and the workflow's base64 decode produces garbage. On GNU coreutils (Linux), `base64 -w0` does this directly; on macOS the `-w` flag doesn't exist, so strip newlines instead. Repeat for `keystore-dev.jks` to populate `ANDROID_DEV_KEYSTORE_BASE64`:

```bash
# Linux (GNU coreutils):
base64 -w0 keystore-release.jks

# macOS / cross-platform:
base64 keystore-release.jks | tr -d '\n'
```

Set the eight secrets with `gh` (swap `base64 -w0` for `base64 … | tr -d '\n'` on macOS):

```bash
gh secret set ANDROID_RELEASE_KEYSTORE_BASE64 --body "$(base64 -w0 keystore-release.jks)"
gh secret set ANDROID_RELEASE_KEYSTORE_PASSWORD --body '…'
gh secret set ANDROID_RELEASE_KEY_ALIAS       --body 'jeeves-release'
gh secret set ANDROID_RELEASE_KEY_PASSWORD     --body '…'
# …and the four ANDROID_DEV_* equivalents.
```

### Verifying a build

`apksigner` ships with the Android SDK build-tools. To inspect the signing certificate of an APK:

```bash
apksigner verify --print-certs path/to/jeeves-<version>.apk
```

The certificate's SHA-256 must match the recorded canonical fingerprint above. `cd-app.yml` runs this step automatically against the production-release APK after each build; for the AAB, run the same command locally against `jeeves-<version>.aab` after downloading it from the release.

### Rotating the release key

Rotation is one-way pain: signature changes force every installed user to uninstall and reinstall, and previously installed APKs cannot be upgraded in place. Only rotate if the key is compromised. (Adopting Play App Signing — see below — lets the upload key rotate freely without user-visible effects, which is the long-term mitigation.)

To rotate:

1. Generate a new keystore as above.
2. Update all four `ANDROID_RELEASE_*` secrets in GitHub.
3. Update the recorded SHA-256 fingerprint in this doc.
4. Bump the version and ship a release. The next CI build will be signed with the new key.
5. Communicate to testers that they must uninstall the old build before installing the new one.

The dev key may be rotated more freely — PR APKs are throwaway and installed only by internal testers.

## Not yet wired

- **Play Store track upload.** GA and rc builds will eventually upload to the Play Store production / internal tracks. Not in place yet.
- **Play App Signing enrollment.** Once enrolled, Play holds the canonical app-signing key and the project keystore becomes an upload-only key that can rotate without forcing reinstalls. Separate work item from this signing rollout.
- **Seeker variant distribution.** The Solana dApp Store APK (`build-seeker` job) is built but not distributed through Firebase; it goes through the dApp Store pipeline separately.
