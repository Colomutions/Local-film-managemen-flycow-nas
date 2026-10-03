FROM dart:3.13.2-sdk AS build

WORKDIR /app

COPY pubspec.yaml pubspec.lock ./
RUN dart pub get

COPY lib ./lib
COPY bin ./bin

RUN dart compile exe bin/mujing_nas.dart -o /tmp/mujing-nas


FROM node:24-bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends libsqlite3-dev ca-certificates ffmpeg unzip poppler-utils util-linux chromium tini \
    && rm -rf /var/lib/apt/lists/*

RUN groupmod --new-name mujing node \
    && usermod --login mujing --home /home/node --shell /usr/sbin/nologin node

WORKDIR /app

COPY --from=build --chown=mujing:mujing /tmp/mujing-nas /app/mujing-nas
COPY --chown=mujing:mujing scraper /app/scraper
RUN chmod -R a+rX /app/scraper

ENV MUJING_BIND_HOST=0.0.0.0 \
    MUJING_PORT=48291 \
    MUJING_DATA_DIR=/data \
    MUJING_MEDIA_DIR=/media \
    MUJING_TIMEZONE=Asia/Shanghai \
    MUJING_SCRAPER_SCRIPT=/app/scraper/worker.mjs \
    BROWSER_EXECUTABLE=/usr/bin/chromium \
    APP_CHROMIUM_NO_SANDBOX=1 \
    XDG_CACHE_HOME=/tmp/chromium-cache \
    XDG_CONFIG_HOME=/tmp/chromium-config

USER mujing

EXPOSE 48291

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["/app/mujing-nas", "--healthcheck"]

ENTRYPOINT ["/usr/bin/tini", "--", "/app/mujing-nas"]
