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

## Not yet wired

- **Firebase App Distribution channels.** Today `pr-apk.yml` distributes PR builds to a `qa` group; `cd-app.yml` doesn't distribute to Firebase at all. Planned channels (audience-named): `dev` (PR builds), `canary` (alphas from main), `beta`, `rc`. A single build fans out to its own channel plus all less-restrictive channels — e.g. a GA build is published to canary, beta, and rc as well, so internal testers aren't stuck on stale pre-releases.
- **Play Store track upload.** GA and rc builds will eventually upload to Play Store production / internal tracks. Not in place yet.
- **Flutter flavor rename.** PR builds currently use `--flavor alpha`, a misnomer — these are dev builds, not alpha builds. Renaming the flavor touches `android/app/build.gradle`, app icons, and signing config and is a separate PR.
