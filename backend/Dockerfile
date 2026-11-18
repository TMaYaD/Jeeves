# Dokku builds this image on deploy, so this line is what production runs.
# Backend CI's `image` job builds the same Dockerfile for linux/amd64 — the
# platform the Dokku host builds — and starts it, so a build that cannot
# finish or an image that cannot serve fails before the deploy.
#
# The tag names the interpreter and the digest pins the bytes, so a Dependabot
# PR reads `3.14.7-slim` → `3.14.8-slim` when CPython moves and leaves the tag
# alone on a base-OS rebuild.  The version must stay inside the
# `requires-python` band in pyproject.toml, which is the single source of truth
# for the interpreter: `pip install -e .` below enforces that at build time,
# and tests/test_python_version.py enforces it by name, without a build.
FROM python:3.14.10-slim@sha256:9aaa474097d094040649f2162a627c0049b408f52138d980916788d80f04802f

WORKDIR /app

COPY pyproject.toml .
RUN pip install --no-cache-dir -e .

COPY . .

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
