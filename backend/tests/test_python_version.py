"""The interpreter version has one source of truth; this is what holds it there.

``requires-python`` in ``pyproject.toml`` is that source.  Ruff infers its
target from it, mypy checks against whatever ``uv run`` resolves out of it, and
Backend CI leaves setup-uv's ``python-version`` unset so the runners resolve it
the same way — none of them carries a second copy of the number.

``Dockerfile`` is the one place that cannot read it, because a ``FROM`` line has
to name a concrete tag.  It is also the line production actually runs: Dokku
builds that image on deploy.  ``pip install -e .`` inside the build does refuse
an interpreter outside the band, but CI never builds the image, so on its own
that check first speaks up as a failed deploy.  Dependabot walked the tag from
3.14.6-slim to 3.15.0rc1-slim through a green CI run and the backend served a
release candidate for three weeks; these two assertions are what make the same
PR go red instead.
"""

import re
import sys
import tomllib
from pathlib import Path

from packaging.specifiers import SpecifierSet
from packaging.version import Version

BACKEND_DIR = Path(__file__).resolve().parents[1]

# `FROM python:3.14.7-slim@sha256:<64 hex>`.  The tag is everything up to the
# digest; the version is the tag up to its first `-`, which drops the `-slim`
# variant suffix and keeps a prerelease marker like `3.15.0rc1`.
_FROM_PYTHON = re.compile(
    r"^FROM\s+python:(?P<tag>[^@\s]+)(?:@sha256:[0-9a-f]{64})?\s*$",
    re.MULTILINE,
)


def _requires_python() -> SpecifierSet:
    with (BACKEND_DIR / "pyproject.toml").open("rb") as pyproject:
        return SpecifierSet(tomllib.load(pyproject)["project"]["requires-python"])


def _dockerfile_python_version() -> Version:
    dockerfile = (BACKEND_DIR / "Dockerfile").read_text()
    match = _FROM_PYTHON.search(dockerfile)
    assert match is not None, (
        "No `FROM python:<tag>` line in backend/Dockerfile. If the base image moved off "
        "the official python image, this test needs to learn how to read the new one — "
        "deleting it would leave the production interpreter unchecked."
    )
    return Version(match.group("tag").split("-", 1)[0])


def test_dockerfile_base_image_satisfies_requires_python() -> None:
    band = _requires_python()
    image_version = _dockerfile_python_version()
    # `contains` rejects prereleases unless the band itself names one, which is
    # what makes an `rc` tag fail here rather than sneaking under the ceiling —
    # PEP 440 sorts 3.15.0rc1 *below* 3.15, so a plain comparison would pass it.
    assert band.contains(image_version), (
        f"backend/Dockerfile runs Python {image_version} in production, which is outside "
        f"`requires-python = {str(band)!r}`. Either revert the base image to a version in "
        f"the band, or widen the band in pyproject.toml and move CI, ruff and mypy with "
        f"it — deliberately, as one change."
    )


def test_test_run_interpreter_satisfies_requires_python() -> None:
    band = _requires_python()
    running = Version(".".join(str(part) for part in sys.version_info[:3]))
    assert band.contains(running, prereleases=True), (
        f"This test run is on Python {running}, outside `requires-python = {str(band)!r}`. "
        f"CI type-checks and tests on the interpreter uv resolves from that band, so a "
        f"mismatch here means the suite is not covering what production runs."
    )
