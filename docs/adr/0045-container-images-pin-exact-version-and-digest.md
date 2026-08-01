# 0045 — Container images pin the exact version *and* the digest

**Status:** accepted (2026-08-01)

## Context

Every container image the project runs — the backend base image, and the
Postgres and Redis services in CI and local dev — was pinned by digest against a
floating major/minor tag: `python:3.14-slim@sha256:…`, `postgres:18-alpine@…`,
`redis:8-alpine@…`. The digest makes the pull immutable, which is the property
that matters for reproducibility and for supply-chain integrity. What it does
not do is say anything a reader can act on.

The consequence shows up in Dependabot's PRs, which are the only place these
pins are ever reviewed. Because the tag does not move, a bump is a bare hex
swap, and the PR title degenerates to *"bump python from `b877e50` to
`cea0e60`"* — or, when the tag is all Dependabot has to work with, to the
literal *"bump redis from 8-alpine to 8-alpine"*. Two of those PRs sat open at
the same time and looked identical; one was a Debian rebuild of an unchanged
CPython, the other an upstream Redis patch release. Nothing on the PR
distinguished them, and finding out meant pulling both images and reading
`PYTHON_VERSION`/`REDIS_VERSION` out of the config blob by hand. A reviewer who
cannot see what changed does not review; they approve.

## Decision

The tag names the exact upstream version; the digest stays. Both are required,
and they have different jobs. **The digest is the contract** — it is what
actually resolves, and it is the only thing that makes the pull immutable. **The
tag is the claim about what that digest contains**, written for a human reading
a diff.

The version pinned is the upstream software's, at full precision
(`3.14.6-slim`, `8.8.1-alpine`, `18.4-alpine`), not the base-OS suffix the
registry also offers (`-slim-trixie`, `-alpine3.23`). The base OS is a property
of the rebuild, and the digest already pins it exactly; spelling it in the tag
as well would narrow the tag stream Dependabot follows for no gain in what a
reviewer learns.

Rejected: **digest only** — immutable, but every update is unreadable, which is
the status quo this replaces. **Tag only** — legible, but a floating tag is not
a pin at all and re-tagging upstream silently changes what runs. **A tolerant
`3.14`-style tag beside the digest** — the middle ground we were already in, and
it hides exactly the distinction (patch move vs rebuild) that a reviewer needs.

## Consequences

An upstream release now moves the tag, so it appears in the PR title and in the
diff: `8.8.1-alpine` → `8.8.2-alpine`. A rebuild of the same release leaves the
tag alone and changes only the digest — which stops being noise and becomes a
specific, readable signal: *the base image was rebuilt, the software was not*.
The two cases are told apart at a glance, and the security-relevant one (a
version you have a CVE for) is named in words.

The redundancy is real and is the point: two facts are asserted where one would
resolve. They can disagree — a hand edit that changes the tag and not the digest
runs the old image under a new name, and nothing in the build fails. The tag is
therefore documentation, and documentation can lie. Dependabot keeps the two
honest wherever it runs, since it rewrites both together; nothing keeps them
honest where it does not, and closing that would need a CI assertion that each
pinned digest really resolves to the version its tag claims — not built here.

Dependabot does not read service-container images out of GitHub Actions workflow
files ([dependabot-core#5819](https://github.com/dependabot/dependabot-core/issues/5819)),
so the Postgres pin in `.github/workflows/backend-ci.yml` is the one reference
nothing updates, and it is updated by hand. It is held byte-identical to the
Postgres pin in `infra/docker-compose.yml` — same tag, same digest — so CI tests
against the image local dev runs, and the two are compared by eye as one string
rather than reasoned about as two. Dependabot bumps the compose side; whoever
merges that bump copies it across. Naming the version is what makes a divergence
legible at all, but it does not prevent one: nothing fails when the two drift,
which is how the CI pin had already fallen a rebuild behind before this decision
was written.
