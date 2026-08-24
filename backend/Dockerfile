FROM python:3.15.0rc1-slim@sha256:d66aca68fc851b8e5b1bc350f7154fe408cf0e85e70c37d18a385591d9bf2743

WORKDIR /app

COPY pyproject.toml .
RUN pip install --no-cache-dir -e .

COPY . .

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
