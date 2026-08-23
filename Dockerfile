# Lantern game + player image. One image, two entrypoints:
#   /bin/lantern         - the game server (default)
#   /bin/lantern-player  - the thin register-and-listen player
#
# Both policy kinds live in this one image and are chosen by env:
#   PLAYER_PROMPT=<strategy text>     an LLM seat
#   PLAYER_SCRIPTED=warden|moth       a scripted seat
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/lantern
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
# Any committed nim.cfg pins the author's machine package paths; regenerate it
# from this container's synced package tree.
RUN rm -f nim.cfg && \
  for pkg in /root/.nimby/pkgs/*; do \
    if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg; \
    else echo "--path:\"$pkg\"" >> nim.cfg; fi; \
  done && \
  echo '--path:"src"' >> nim.cfg && \
  nim c -d:release -d:useMalloc --opt:speed --stackTrace:on \
    --nimcache:/tmp/lantern-nimcache --out:lantern src/lantern.nim && \
  nim c -d:release -d:useMalloc --opt:speed --stackTrace:on \
    --nimcache:/tmp/lantern-player-nimcache --out:lantern-player \
    src/lantern_player.nim

# Run image.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/lantern
COPY --from=build /workspace/lantern/lantern /bin/lantern
COPY --from=build /workspace/lantern/lantern-player /bin/lantern-player
COPY --from=build /workspace/lantern/data ./data
COPY --from=build /workspace/lantern/client ./client

CMD ["/bin/lantern"]
