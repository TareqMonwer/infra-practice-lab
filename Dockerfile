# syntax=docker/dockerfile:1.7
FROM python:3.13.1-alpine3.21 AS build
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt
FROM python:3.13.1-alpine3.21
ARG VERSION=1.0.0
LABEL org.opencontainers.image.title="devops-assessment" org.opencontainers.image.version="$VERSION" org.opencontainers.image.source="https://github.com/example/devops-assessment"
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PORT=8000
RUN addgroup -S app && adduser -S -G app app
WORKDIR /app
COPY --from=build /install /usr/local
COPY --chown=app:app app ./app
USER app
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)" || exit 1
CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000} --timeout-graceful-shutdown 20"]
