# 25. The server is versioned independently of the app, on a four-segment pre-1.0 scheme

## Status

Accepted

## Context

The backend and the Flutter app shipped as one version story that never actually existed: `cd-app.yml` computes an app version from conventional commits and tags it `v*`, while the server's version was a literal `0.1.0` written twice — once in `backend/pyproject.toml`, once in the `FastAPI(...)` constructor — and never changed by anything. `/health` reported no version at all. With the Minimal Sync Server rewrite replacing the PowerSync protocol, client/server skew stops being hypothetical, and "which server did this client talk to?" needs an answer that is not deploy folklore.

Giving the server the app's version would be worse than no version: the app releases far more often, and the numbers would imply a coupling that does not exist. So the server gets its own namespace, its own bump rules, and its own pipeline — and the versions are computed from *backend-touching commits only*, so an app-only week leaves the server version alone.

## Decision

**The server versions independently, on a scheme that is ordinary SemVer behind a `0.` prefix.** Published versions read `0.X.Y`, and `0.X.Y.Z` once an inner patch exists; the inner X.Y.Z is where the SemVer contract lives. The last untagged server is anchored at a seeded baseline tag, and the rewrite's first breaking merge takes it to `0.1.0` by the ordinary rules rather than by a special case.

**The mechanism is a ~150-line bash script, not an off-the-shelf release tool.** No mainstream tool — semantic-release, python-semantic-release, release-please, paulhatch/semantic-version — can emit a four-segment version, and none does per-commit path-filtered classification without monorepo-package machinery that still emits three segments. Bending one means post-processing its output and fighting its tag conventions. The script matches the house style instead: `cd-app.yml` already hand-rolls the same subject-anchored commit walk in bash, and `infra/dokku/` already shows how such scripts are shellcheck-linted and covered by a scratch-repo test harness.

**A range of nothing but chore/refactor/dependency commits still bumps the patch.** Roughly half of recent backend commits are typed that way and several were runtime-changing dependency bumps; without that floor they would deploy new code under an unchanged version and a `/health` that lies. "No bump" means "nothing touched the backend", and nothing else.

Policy and pointers live in `docs/BACKEND_GUIDELINES.md`, "Server versioning & releases"; the tag prefix, path filter and bump rules live in `infra/ci/compute-server-version.sh`, which is the single source of truth for all three.

## Trade-off

**The four-segment version is the surprising part, and it is a real cost.** It is not valid SemVer as a string: tooling that parses versions will reject or mangle `0.1.0.1`, and no package registry would accept it. It is accepted because nothing consumes the server version as a package — it is a deploy label read by humans and reported by `/health` — and because the alternative, spending the top-level minor on every backend feature, would put the project at `1.0` on the strength of a routine feature rather than a deliberate commitment. The `0.` prefix is a statement that the whole server is pre-commitment; the arithmetic beneath it stays honest.

**Tags are cut before the deploy, not after.** A failed deploy therefore leaves a tag for code that never ran. That is preferred to the inverse: tagging afterwards lets an unrelated late-stage failure withhold a tag from a backend that did ship, and the version is a property of the release cut while `/health` is what reports deployed reality. The next successful deploy converges the two, because the version injection runs on every deploy rather than only when a tag was cut.

**The baseline is seeded by hand, once.** The script hard-fails on an empty tag namespace rather than inventing a starting point. A bootstrap special case ("no tag → 0.1.0") was rejected: it would contradict the per-type bump rules for any pre-rewrite backend commit and hide the interesting decision inside a branch nobody would read twice.

**Version injection is a deploy-time environment variable, which a hand-rolled `git push dokku` bypasses.** Dokku builds from a git archive with no `.git`, so `git describe` at runtime is not available and the process genuinely cannot know its own version without being told. The `0.0.0-dev` default keeps an untold server honest rather than letting it claim someone else's release.
