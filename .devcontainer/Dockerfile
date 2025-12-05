# Dockerfile
FROM mcr.microsoft.com/devcontainers/base:noble

# Avoid interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

# Core packages for Apache + AHTSE toolchain
RUN apt-get update -y && \
    apt-get install -y \
      apache2 apache2-dev \
      gdal-bin libgdal-dev \
      build-essential cmake pkg-config \
      libapr1-dev libaprutil1-dev \
      libjpeg-dev libpng-dev zlib1g-dev \
      libcurl4-openssl-dev \
      sqlite3 libsqlite3-dev \
      git \
    && rm -rf /var/lib/apt/lists/*
