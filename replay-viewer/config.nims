import std/[os, strformat, strutils]

let rootDir = currentSourcePath().parentDir().parentDir()
let distDir = rootDir / "replay-viewer" / "dist"

if not dirExists(distDir):
  mkDir(distDir)

switch("path", rootDir / "src")
switch("nimcache", distDir / "nimcache")
switch("threads", "off")
--os:linux
--cpu:wasm32
--cc:clang
--clang.exe:emcc
--clang.linkerexe:emcc
--clang.cpp.exe:emcc
--clang.cpp.linkerexe:emcc
--mm:arc
--exceptions:goto
--define:noSignalHandler
--define:release
# Route allocations through emscripten's malloc; with Nim's own allocator a
# bad free silently poisons the freelists, dlmalloc traps loudly instead.
--define:useMalloc

# ABORTING_MALLOC: with -d:useMalloc Nim never checks malloc for nil, and
# wasm32 has no memory protection, so a failed allocation would write through
# the nil pointer into address 0 and corrupt the module's globals.
#
# No fast-math relaxation is passed here, deliberately: the sim is
# integer-only and the emscripten build has to agree with the native build bit
# for bit. tests/test_vision.nim greps every build script for the flag.
switch(
  "passL",
  (&"""
  -o {distDir / "lantern_replay.js"}
  -O2
  -s ALLOW_MEMORY_GROWTH
  -s ABORTING_MALLOC=1
  -s ENVIRONMENT=web,worker,node
  -s MODULARIZE=1
  -s EXPORT_NAME=LanternReplayModule
  -s EXPORTED_RUNTIME_METHODS=HEAPU8
  -s EXPORTED_FUNCTIONS=_main,_malloc,_free,_lt_load_replay,_lt_frame,_lt_seek,_lt_tick,_lt_tick_count,_lt_mismatch_tick,_lt_meta_ptr,_lt_meta_len,_lt_packet_ptr,_lt_packet_len,_lt_error_ptr,_lt_error_len,_lt_stage_ptr,_lt_stage_len
  """).replace("\n", " ")
)
