FROM dart:3.3-sdk AS build

WORKDIR /app
COPY pubspec.yaml ./
COPY lib ./lib
COPY bin ./bin
RUN dart compile exe bin/mujing_nas.dart -o /tmp/mujing-nas

FROM debian:bookworm-slim

RUN groupadd --gid 1000 mujing \
    && useradd --uid 1000 --gid mujing --create-home --shell /usr/sbin/nologin mujing

WORKDIR /app
COPY --from=build --chown=mujing:mujing /tmp/mujing-nas /app/mujing-nas

ENV MUJING_BIND_HOST=0.0.0.0 \
    MUJING_PORT=48291 \
    MUJING_DATA_DIR=/data \
    MUJING_MEDIA_DIR=/media \
    MUJING_TIMEZONE=Asia/Shanghai

USER mujing
EXPOSE 48291
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["/app/mujing-nas", "--healthcheck"]

ENTRYPOINT ["/app/mujing-nas"]

