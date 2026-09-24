#!/bin/bash
# Build the portable Apple Silicon package of Geant4 example B2a.
#
#   ./build_mac.sh deps   Qt (official binaries) + Xerces-C (static) + Geant4 (static) + EM datasets -> deps/
#   ./build_mac.sh app    B2a -> exampleB2a.app (Qt bundled, data inside) -> dist/exampleB2a-macos-arm64.zip
#   ./build_mac.sh        both
#
# Runs on any Apple Silicon Mac with Xcode >= 16, CMake >= 3.16 and python3 (same script as CI).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/versions.env"
DEPS="$ROOT/deps"
PREFIX="$DEPS/install"
QT="$DEPS/qt/$QT_VERSION/macos"
JOBS="$(sysctl -n hw.ncpu)"
# Bundled datasets, <tarball>:<directory>:<md5> from Geant4 11.4.2 cmake/Modules/G4DatasetDefinitions.cmake
#  G4EMLOW            EM low-energy data (Livermore photoelectric/Rayleigh, Seltzer-Berger bremsstrahlung, ...)
#  G4ENSDFSTATE       nuclide table, read by /run/initialize even for EM-only physics
#  PhotonEvaporation  since 11.4.2, G4EmBuilder -> G4PhysListUtil::InitialiseParameters -> G4NuclearLevelData
#                     -> G4LevelReader aborts at start-up (had014) if this directory cannot be found
G4_DATASETS="
G4EMLOW.8.8:G4EMLOW8.8:328330009df633f7e9b3a9f445745298
G4ENSDFSTATE.3.0:G4ENSDFSTATE3.0:c500728534ce3e9fb2fefa0112eb3a74
G4PhotonEvaporation.6.1.2:PhotonEvaporation6.1.2:d80ba9bdefcf9e23487a26adfa273304"
# G4EMLOW subdirectories for physics this binary cannot run (DNA, MicroElec, DPWA and
# JAEA elastic, Goudsmit-Saunderson msc): 611 of 697 MB. test_package.sh proves they are not read.
EMLOW_DROP="dna microelec dpwa JAEAESData msc_GS"

CMAKE_COMMON=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN"
  -DCMAKE_PREFIX_PATH="$QT;$PREFIX"
)
G4_FLAGS=(
  -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON
  -DGEANT4_BUILD_MULTITHREADED=ON
  -DGEANT4_USE_QT=ON
  -DGEANT4_USE_GDML=ON
  -DGEANT4_USE_SYSTEM_EXPAT=OFF -DGEANT4_USE_SYSTEM_ZLIB=OFF
  -DGEANT4_INSTALL_DATA=OFF -DGEANT4_INSTALL_EXAMPLES=OFF
)

fetch() { curl -fsSL --retry 3 "$1"; }

build_deps() {
  mkdir -p "$DEPS/src" "$DEPS/build" "$PREFIX/share/licenses" "$DEPS/data"

  # Qt 6: official universal binaries (dynamic frameworks, bundled later by macdeployqt)
  if [ ! -x "$QT/bin/macdeployqt" ]; then
    python3 -m venv "$DEPS/venv"
    "$DEPS/venv/bin/pip" install --quiet aqtinstall
    "$DEPS/venv/bin/aqt" install-qt mac desktop "$QT_VERSION" clang_64 -O "$DEPS/qt"
    rm -rf "$DEPS/venv"
    fetch https://www.gnu.org/licenses/lgpl-3.0.txt > "$PREFIX/share/licenses/Qt-LGPL-3.0.txt"
    fetch https://www.gnu.org/licenses/gpl-3.0.txt > "$PREFIX/share/licenses/Qt-GPL-3.0.txt"
  fi

  # Xerces-C (GDML): static, no network accessor, libc transcoder -> no extra link dependencies
  if [ ! -f "$PREFIX/lib/libxerces-c.a" ]; then
    fetch "https://archive.apache.org/dist/xerces/c/3/sources/xerces-c-$XERCES_VERSION.tar.gz" | tar xz -C "$DEPS/src"
    cmake -S "$DEPS/src/xerces-c-$XERCES_VERSION" -B "$DEPS/build/xerces" "${CMAKE_COMMON[@]}" \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" \
      -DBUILD_SHARED_LIBS=OFF -Dnetwork=OFF -Dtranscoder=iconv -Dmessage-loader=inmemory
    cmake --build "$DEPS/build/xerces" --parallel "$JOBS"
    cmake --install "$DEPS/build/xerces"
    cp "$DEPS/src/xerces-c-$XERCES_VERSION/LICENSE" "$PREFIX/share/licenses/Xerces-C-LICENSE.txt"
    cp "$DEPS/src/xerces-c-$XERCES_VERSION/NOTICE" "$PREFIX/share/licenses/Xerces-C-NOTICE.txt"
  fi

  # Geant4: static libraries, Qt + OpenGL visualisation, GDML
  if [ ! -x "$PREFIX/bin/geant4-config" ]; then
    fetch "https://geant4-data.web.cern.ch/releases/geant4-v$G4_VERSION.tar.gz" | tar xz -C "$DEPS/src"
    cmake -S "$DEPS/src/geant4-v$G4_VERSION" -B "$DEPS/build/geant4" "${CMAKE_COMMON[@]}" \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" "${G4_FLAGS[@]}"
    cmake --build "$DEPS/build/geant4" --parallel "$JOBS"
    cmake --install "$DEPS/build/geant4"
    cp "$DEPS/src/geant4-v$G4_VERSION/LICENSE" "$PREFIX/share/licenses/Geant4-LICENSE.txt"
  fi
  rm -rf "$DEPS/src" "$DEPS/build"

  # EM datasets (md5-checked); their versions must be the ones this Geant4 looks for
  local known
  known="$("$PREFIX/bin/geant4-config" --datasets)"
  for entry in $G4_DATASETS; do
    IFS=: read -r file dir md5 <<< "$entry"
    grep -q "/$dir\$" <<< "$known" \
      || { echo "Geant4 $G4_VERSION does not use $dir: update G4_DATASETS in build_mac.sh"; exit 1; }
    [ -d "$DEPS/data/$dir" ] && continue
    curl -fL --retry 3 -o "$DEPS/data/$file.tar.gz" "https://cern.ch/geant4-data/datasets/$file.tar.gz"
    [ "$(md5 -q "$DEPS/data/$file.tar.gz")" = "$md5" ] || { echo "md5 mismatch for $file"; exit 1; }
    tar xzf "$DEPS/data/$file.tar.gz" -C "$DEPS/data"
    rm "$DEPS/data/$file.tar.gz"
  done
}

build_app() {
  local pkg="$ROOT/dist/exampleB2a-macos-arm64"
  local app="$pkg/exampleB2a.app"
  local res="$app/Contents/Resources"

  cmake -S "$ROOT/B2a" -B "$ROOT/build/B2a" "${CMAKE_COMMON[@]}"
  cmake --build "$ROOT/build/B2a" --parallel "$JOBS"

  rm -rf "$ROOT/dist"
  mkdir -p "$pkg"
  cp -R "$ROOT/build/B2a/exampleB2a.app" "$app"

  # Qt frameworks and plugins into Contents/Frameworks and Contents/PlugIns
  "$QT/bin/macdeployqt" "$app" -verbose=1
  install_name_tool -delete_rpath "$QT/lib" "$app/Contents/MacOS/exampleB2a" 2>/dev/null || true

  # Macros and EM datasets inside the bundle (main() points GEANT4_DATA_DIR there)
  mkdir -p "$res/data"
  cp "$ROOT"/B2a/*.mac "$res/"
  for entry in $G4_DATASETS; do
    IFS=: read -r _ dir _ <<< "$entry"
    cp -R "$DEPS/data/$dir" "$res/data/"
  done
  for d in $EMLOW_DROP; do rm -rf "$res"/data/G4EMLOW*/"$d"; done
  plutil -replace CFBundleIdentifier -string io.github.davsar89.exampleB2a "$app/Contents/Info.plist"
  plutil -replace NSHighResolutionCapable -bool true "$app/Contents/Info.plist"

  # arm64 code must be signed; ad-hoc signature (no Apple Developer ID)
  codesign --force --deep --sign - "$app"
  codesign --verify --deep --strict "$app"

  cp "$ROOT/run.command" "$ROOT/test_package.sh" "$ROOT/README.md" "$pkg/"
  chmod +x "$pkg/run.command" "$pkg/test_package.sh"
  cp -R "$PREFIX/share/licenses" "$pkg/licenses"

  {
    echo "exampleB2a portable package for macOS arm64"
    echo "built:       $(date -u '+%Y-%m-%d %H:%M UTC')"
    echo "git commit:  $(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "build host:  macOS $(sw_vers -productVersion), $(xcodebuild -version | head -1), $(cmake --version | head -1)"
    echo "compiler:    $(clang --version | head -1)"
    echo
    grep -v '^#' "$ROOT/versions.env"
    echo
    echo "Geant4 CMake flags: ${CMAKE_COMMON[*]} ${G4_FLAGS[*]}"
    echo "Physics: G4EmStandardPhysics (option 0) + G4StepLimiterPhysics, production cut 0.7 mm"
    echo
    echo "Bundled datasets (Contents/Resources/data):"
    du -sh "$res"/data/* | sed "s|$res/data/||"
    echo "Removed from G4EMLOW: $EMLOW_DROP"
    echo
    echo "Dynamic libraries of the executable:"
    otool -L "$app/Contents/MacOS/exampleB2a" | tail -n +2
  } > "$pkg/BUILD_INFO.txt"

  (cd "$ROOT/dist" && ditto -c -k --keepParent exampleB2a-macos-arm64 exampleB2a-macos-arm64.zip)
  du -sh "$app" "$ROOT/dist/exampleB2a-macos-arm64.zip"
}

case "${1:-all}" in
  deps) build_deps ;;
  app)  build_app ;;
  all)  build_deps; build_app ;;
  *)    echo "usage: $0 [deps|app]"; exit 1 ;;
esac
