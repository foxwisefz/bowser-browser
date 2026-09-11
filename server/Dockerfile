# Build from repository root: docker build -f server/Dockerfile -t bowser-server:local .
ARG BUILDER_IMAGE=hexpm/elixir:1.18.4-erlang-27.3.4.2-debian-bookworm-20250811-slim
ARG RUNNER_IMAGE=debian:bookworm-slim
FROM ${BUILDER_IMAGE} AS build
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git ca-certificates && rm -rf /var/lib/apt/lists/*
ENV MIX_ENV=prod
WORKDIR /build/server
RUN mix local.hex --force && mix local.rebar --force
COPY server/mix.exs server/mix.lock ./
COPY server/config ./config
RUN HEX_HTTP_CONCURRENCY=1 HEX_HTTP_TIMEOUT=60 mix deps.get --only prod && mix deps.compile
COPY server/lib ./lib
COPY website /build/website
RUN mix release

FROM ${RUNNER_IMAGE} AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates curl && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 bowser && useradd --uid 10001 --gid bowser --no-create-home bowser \
    && mkdir -p /app /data /backups /downloads && chown bowser:bowser /data /backups
ENV RELEASE_TMP=/tmp ERL_CRASH_DUMP=/tmp/erl_crash.dump LANG=C.UTF-8 PHX_SERVER=true HOST=0.0.0.0 PORT=8080 BOWSER_INTERNAL_HTTP=1 BOWSER_DATABASE=/data/bowser.sqlite
WORKDIR /app
COPY --from=build --chown=bowser:bowser /build/server/_build/prod/rel/bowser_server ./
USER 10001:10001
EXPOSE 8080
STOPSIGNAL SIGTERM
CMD ["/app/bin/bowser_server", "start"]
