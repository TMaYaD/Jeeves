# Backend Guidelines

This document outlines the architectural and engineering guidelines specific to the Jeeves backend service.

## 12-Factor App Methodology

The Jeeves FastAPI service is built following the [12-Factor App methodology](https://12factor.net/). This ensures that our backend is scalable, portable, and resilient.

### 1. Codebase
- **Principle:** One codebase tracked in revision control, many deploys.
- **Application:** The backend resides in the `backend/` directory of our mono-repo. The same codebase is deployed across all environments (local, staging, production).

### 2. Dependencies
- **Principle:** Explicitly declare and isolate dependencies.
- **Application:** We use explicit dependency management (e.g., `requirements.txt` or `pyproject.toml`) and execute inside isolated environments (like Docker containers and Python virtual environments).

### 3. Config
- **Principle:** Store config in the environment.
- **Application:** All configuration (database URLs, API keys, feature flags) is passed via environment variables (often loaded via `.env` files locally using `pydantic-settings`). We do not store secrets in source code.

### 4. Backing Services
- **Principle:** Treat backing services as attached resources.
- **Application:** PostgreSQL, Redis, and Anthropic API are treated as external resources. The backend can swap them out by simply changing environment variables without requiring code changes.

### 5. Build, Release, Run
- **Principle:** Strictly separate build and run stages.
- **Application:** Docker images are built as a distinct artifact, tagged, and then released for running. Deployments are separate from the build process.

### 6. Processes
- **Principle:** Execute the app as one or more stateless processes.
- **Application:** The FastAPI and Celery processes are entirely stateless. Any persistent state (sessions, cache, long-term data) is offloaded to PostgreSQL or Redis.

### 7. Port Binding
- **Principle:** Export services via port binding.
- **Application:** Our FastAPI service uses `uvicorn` to bind to a port (usually 8000) and expose its HTTP API directly.

### 8. Concurrency
- **Principle:** Scale out via the process model.
- **Application:** We scale HTTP traffic by adding more Uvicorn workers or horizontally scaling the FastAPI containers. We scale background jobs by adding Celery workers.

### 9. Disposability
- **Principle:** Maximize robustness with fast startup and graceful shutdown.
- **Application:** Containers are designed to start quickly. They handle SIGTERM signals gracefully to drain connections and finish processing requests before shutting down.

### 10. Dev/Prod Parity
- **Principle:** Keep development, staging, and production as similar as possible.
- **Application:** We use `infra/` (Docker Compose) to run the exact same PostgreSQL and Redis infrastructure locally that we use in production.

### 11. Logs
- **Principle:** Treat logs as event streams.
- **Application:** The application logs to standard output/error (stdout/stderr). Log routing and storage are handled by the infrastructure layer, not the application itself.

### 12. Admin Processes
- **Principle:** Run admin/management tasks as one-off processes.
- **Application:** Database migrations (`alembic upgrade`) and administrative scripts are run as isolated one-off commands against a release within the same environment as the long-running processes.
