# Builder only compiles the module. The runtime image does not keep build caches.
FROM python:3.12.16-slim-trixie AS builder

WORKDIR /build
COPY app.py .
RUN python -m py_compile app.py

FROM python:3.12.16-slim-trixie

# Pick up distro security fixes that already exist for this base (for example zlib1g).
# Packages with no fix yet are left as they are; the Trivy gate reports those.
RUN apt-get update \
    && apt-get upgrade -y \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 10001 app \
    && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin app

WORKDIR /app
COPY --from=builder /build/app.py /app/app.py

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080

USER 10001:10001

EXPOSE 8080

CMD ["python", "/app/app.py"]
