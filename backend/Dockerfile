FROM python:3.14-slim@sha256:f54c5f39326ef06c7cb7f5fc57025aa5b7a1d3367cea42d8b5d3c8e082338ec5

WORKDIR /app

COPY pyproject.toml .
RUN pip install --no-cache-dir -e .

COPY . .

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
