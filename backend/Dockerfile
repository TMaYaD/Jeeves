# Dokku builds this image on deploy, so this line is what production runs —
# and CI never builds it, so nothing here is exercised before the deploy.
#
# The tag names the interpreter and the digest pins the bytes, so a Dependabot
# PR reads `3.14.7-slim` → `3.14.8-slim` when CPython moves and leaves the tag
# alone on a base-OS rebuild.  The version must stay inside the
# `requires-python` band in pyproject.toml, which is the single source of truth
# for the interpreter: `pip install -e .` below enforces that here at build
# time, and tests/test_python_version.py enforces it in CI, where this image is
# never built.
FROM python:3.15.0rc3-slim@sha256:a3af3d230522dd52f7f2191b39e1892912dbcb0c8dee22afdec3dc83baf0f549

WORKDIR /app

COPY pyproject.toml .
RUN pip install --no-cache-dir -e .

COPY . .

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
