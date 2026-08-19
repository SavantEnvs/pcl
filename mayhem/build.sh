#!/usr/bin/env bash
#
# mayhem/build.sh — build PCL's `ply_reader_fuzzer` harness (the same harness OSS-Fuzz builds via
# test/fuzz/build.sh) plus the io/common/octree unit test suite that mayhem/test.sh runs.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# CMake options common to both builds below: only the subsystems the harness (and its tests)
# actually exercise — common, octree, io (io's own SUBSYS_DEPS) — everything else off so the
# build stays fast and needs no VTK/Qt/CUDA/PCAP/OpenGL/FLANN/libusb.
MINIMAL_OPTS=(
  -DPCL_SHARED_LIBS=OFF
  -DWITH_CUDA=OFF -DWITH_OPENMP=OFF -DWITH_LIBUSB=OFF -DWITH_PNG=OFF -DWITH_QHULL=OFF
  -DWITH_GLEW=OFF -DWITH_VTK=OFF -DWITH_PCAP=OFF -DWITH_OPENGL=OFF
  -DBUILD_2d=OFF -DBUILD_apps=OFF -DBUILD_benchmarks=OFF -DBUILD_examples=OFF
  -DBUILD_features=OFF -DBUILD_filters=OFF -DBUILD_geometry=OFF
  -DBUILD_kdtree=OFF -DBUILD_keypoints=OFF -DBUILD_ml=OFF -DBUILD_outofcore=OFF
  -DBUILD_people=OFF -DBUILD_recognition=OFF -DBUILD_registration=OFF
  -DBUILD_sample_consensus=OFF -DBUILD_search=OFF -DBUILD_segmentation=OFF -DBUILD_simulation=OFF
  -DBUILD_stereo=OFF -DBUILD_surface=OFF -DBUILD_tools=OFF -DBUILD_tracking=OFF
  -DBUILD_visualization=OFF
)

# 1) Build the PROJECT ITSELF (common/octree/io) sanitized + with DWARF<=3 debug info, so the
#    fuzzed code is instrumented and backtraces resolve project source lines. $DEBUG_FLAGS goes
#    AFTER $SANITIZER_FLAGS so its -gdwarf-3 wins over any -g the sanitizer flags carry.
cmake -B build -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
      -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
      -DBUILD_global_tests=OFF \
      "${MINIMAL_OPTS[@]}" \
      -S . -B build
cmake --build build -j"$MAYHEM_JOBS" --target pcl_common pcl_octree pcl_io pcl_io_ply

# 2) Compile the ply_reader_fuzzer harness (shared by OSS-Fuzz's test/fuzz/build.sh) TWICE:
#    once linking the fuzzing engine (the fuzzer binary Mayhem runs), once linking the standalone
#    run-once driver (a non-fuzzer reproducer). Both respect $SANITIZER_FLAGS + $DEBUG_FLAGS.
HARNESS="$SRC/test/fuzz/ply_reader_fuzzer.cpp"
HARNESS_CXXFLAGS=(-DPCLAPI_EXPORTS
  -I"$SRC/build/include" -I"$SRC/common/include" -I"$SRC/io/include" -I"$SRC/octree/include"
  -isystem /usr/include/eigen3
  $SANITIZER_FLAGS $DEBUG_FLAGS -DNDEBUG -fPIC -std=c++17)
LIBS=("$SRC/build/lib/libpcl_io.a" "$SRC/build/lib/libpcl_io_ply.a" \
      "$SRC/build/lib/libpcl_octree.a" "$SRC/build/lib/libpcl_common.a")

# shellcheck disable=SC2086
$CXX "${HARNESS_CXXFLAGS[@]}" $LIB_FUZZING_ENGINE \
    "$HARNESS" "${LIBS[@]}" -lm -o /mayhem/ply_reader_fuzzer

# C++ harness: compile the standalone driver as C first (clang++ would mangle its
# LLVMFuzzerTestOneInput reference), then link it (not the fuzzing engine) against the harness.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
# shellcheck disable=SC2086
$CXX "${HARNESS_CXXFLAGS[@]}" \
    "$HARNESS" /tmp/standalone_main.o "${LIBS[@]}" -lm -o /mayhem/ply_reader_fuzzer-standalone

# 3) Build the project's io/common/octree unit tests with NORMAL flags (clean, independent build —
#    not the sanitized fuzz build above) so mayhem/test.sh only RUNS them. libgtest-dev ships the
#    gtest SOURCE (no prebuilt lib) which PCL's FindGTestSource.cmake compiles itself — fully
#    offline, no network fetch.
# tests_registration doesn't gate on BUILD_registration (an upstream test/registration/CMakeLists.txt
# gap: PCL_SUBSYS_DEPEND fails to disable it when the registration module itself is off) — force it
# off explicitly rather than patch the upstream file (this layer stays additive-only).
cmake -B build-tests -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
      -DBUILD_global_tests=ON -DBUILD_tests_registration=OFF \
      "${MINIMAL_OPTS[@]}" \
      -S . -B build-tests
cmake --build build-tests -j"$MAYHEM_JOBS"
