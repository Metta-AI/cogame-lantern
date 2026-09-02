#!/usr/bin/env bash
# Coworld replay-viewer build hook: invoked by `coworld build` with one
# argument, the absolute path of the static bundle directory to produce
# (<manifest-dir>/static-replay-viewer, which must end up containing
# index.html). `coworld build` refuses to package a source replay-viewer
# bundle unless this file is os.X_OK, so it is committed mode 100755.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 /absolute/path/to/static-replay-viewer" >&2
  exit 1
fi

output_dir="$1"
if [[ "${output_dir}" != /* ]]; then
  echo "output dir must be absolute: ${output_dir}" >&2
  exit 1
fi
if [[ "$(basename "${output_dir}")" != "static-replay-viewer" ]]; then
  echo "output dir must be named static-replay-viewer: ${output_dir}" >&2
  exit 1
fi

export PATH="$HOME/.nimby/nim/bin:$PATH"

if command -v emcc >/dev/null && command -v nim >/dev/null; then
  # Local toolchain: build the wasm module and assemble dist/ directly.
  (
    cd "${repo_dir}"
    nim c --hints:off -d:emscripten replay-viewer/lantern_replay.nim
    nim r --hints:off --path:src tools/gen_wire_constants.nim \
      > replay-viewer/dist/wire_constants.js
    cp client/chrome_common.js client/broadcast_core.js replay-viewer/dist/
    cp replay-viewer/static_replay.js replay-viewer/static_replay_worker.js \
      replay-viewer/dist/
    mkdir -p replay-viewer/dist/art
    cp client/art/*.png client/art/*.jpg replay-viewer/dist/art/
    cp data/font.ttf replay-viewer/dist/font.ttf
    sed -e 's|<!-- WIRE_CONSTANTS -->|<script src="./wire_constants.js"></script>|' \
        -e 's|<!-- CHROME_COMMON -->|<script src="./chrome_common.js"></script>|' \
        -e 's|<!-- BROADCAST_CORE -->|<script src="./static_replay.js"></script>|' \
        client/replay_broadcast.html > replay-viewer/dist/index.html
  )
else
  # Fall back to the pinned emsdk container (the CI runner has no emcc).
  image_tag="lantern-replay-viewer-build:$$"
  docker build --platform linux/amd64 \
    --file "${repo_dir}/Dockerfile.replay-viewer" \
    --tag "${image_tag}" "${repo_dir}"
  container_id="$(docker create "${image_tag}")"
  rm -rf "${repo_dir}/replay-viewer/dist"
  docker cp "${container_id}:/workspace/lantern/replay-viewer/dist" \
    "${repo_dir}/replay-viewer/dist"
  docker rm "${container_id}" >/dev/null
  docker image rm "${image_tag}" >/dev/null
fi

dist="${repo_dir}/replay-viewer/dist"
test -s "${dist}/lantern_replay.wasm"
test -s "${dist}/lantern_replay.js"
test -s "${dist}/index.html"

rm -rf "${output_dir}"
mkdir -p "${output_dir}/art"
cp "${dist}/index.html" "${dist}/static_replay.js" \
   "${dist}/static_replay_worker.js" "${dist}/chrome_common.js" \
   "${dist}/broadcast_core.js" "${dist}/wire_constants.js" \
   "${dist}/lantern_replay.js" "${dist}/lantern_replay.wasm" \
   "${dist}/font.ttf" "${output_dir}/"
cp "${dist}"/art/* "${output_dir}/art/"

test -f "${output_dir}/index.html"
grep -q 'coworld-replay' "${output_dir}/static_replay.js"
grep -q "tell('ready')" "${output_dir}/static_replay.js"
grep -q "tell('phase'" "${output_dir}/static_replay.js"
grep -q 'data-replay-loaded' "${output_dir}/static_replay.js"
grep -q 'replay_fetch_end' "${output_dir}/static_replay_worker.js"
grep -q 'DecompressionStream' "${output_dir}/static_replay_worker.js"

# The node harness runs the real wasm module against a recorded replay and
# asserts the tick total and the final digest. It is skipped only when node is
# absent; CI always has it.
if command -v node >/dev/null && [[ -f "${repo_dir}/tools/wasm_replay_smoke.cjs" ]]; then
  node "${repo_dir}/tools/wasm_replay_smoke.cjs" "${dist}"
fi

echo "lantern replay viewer bundle: ${output_dir}"
