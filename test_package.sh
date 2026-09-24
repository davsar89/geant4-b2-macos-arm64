#!/bin/bash
# Self-test of the portable exampleB2a package. Needs nothing installed.
# Usage (from the unzipped folder):  ./test_package.sh [--data-usage]
#
#  1. binary is arm64 and uses only macOS system libraries or libraries inside the bundle
#  2. the B2 macros run cleanly with only the bundled datasets
#  3. physics: 6 MeV gamma attenuation in the 5 cm lead target vs NIST XCOM and vs Geant4's formulas
#  4. GDML: exporting the geometry and reading it back gives the same physics and tracker hits
#  5. (--data-usage, information) which bundled datasets / G4EMLOW subdirectories the physics reads.
#     It makes Geant4 abort on purpose, so macOS shows "quit unexpectedly" dialogs.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/exampleB2a.app"
EXE="$APP/Contents/MacOS/exampleB2a"
RES="$APP/Contents/Resources"

# Use only the bundled datasets
unset GEANT4_DATA_DIR $(env | sed -n 's/^\(G4[A-Z0-9_]*DATA\)=.*/\1/p')

WORK="${TEST_WORKDIR:-$(mktemp -d)}"  # CI sets TEST_WORKDIR to keep the logs
mkdir -p "$WORK" && cd "$WORK" || exit 1
echo "Logs in $WORK"

fails=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }

# run <log> <args...>: batch run; fails on a non-zero exit, a G4Exception error or an interrupted macro
run() {
  local log="$1"; shift
  if "$EXE" "$@" > "$log" 2>&1 \
     && ! grep -qE 'EEEE ------- G4Exception-START|Batch is interrupted|Can not open a macro file' "$log"; then
    pass "exampleB2a $* ($log)"
  else
    fail "exampleB2a $* ($log)"; tail -n 40 "$log"
  fi
}

echo "== 1. Binary and linking"
file "$EXE" | grep -q 'arm64' && pass "arm64 executable" || fail "not arm64: $(file "$EXE")"
if xcode-select -p > /dev/null 2>&1; then  # otool comes with the Xcode command line tools
  echo "      minimum macOS: $(otool -l "$EXE" | awk '/LC_BUILD_VERSION/ {f = 1} f && /minos/ {print $2; exit}')"
  bad=$(find "$APP" -path "$RES/data" -prune -o -type f -print | while read -r f; do
          file "$f" | grep -q 'Mach-O' || continue
          otool -arch arm64 -L "$f" | tail -n +2 | awk '{print $1}' \
            | grep -vE '^(/usr/lib/|/System/Library/|@rpath/|@executable_path/|@loader_path/)' | sed "s|^|$f: |"
        done)
  [ -z "$bad" ] && pass "only macOS system libraries and bundled Qt" || { fail "external library dependencies:"; echo "$bad"; }
else
  echo "SKIP  library check (needs the Xcode command line tools; the runs below still prove the app starts)"
fi

echo "== 2. B2 macros with the bundled data"
run run1.log run1.mac
run smoke.log smoke.mac

echo "== 3. Physics: uncollided 6 MeV gamma transmission through 5 cm of lead vs NIST XCOM"
# mu/rho(Pb, 6 MeV) without coherent scattering = 0.04382 cm2/g (NIST XCOM). Rayleigh-scattered photons
# (at most a few tens of mrad at 6 MeV, i.e. < 3 mm off axis at the cell) keep their energy and still hit
# the 2x2 cm cell, so they count as uncollided; coherent is anyway only 0.2% of mu here.
# rho(G4_Pb) = 11.35 g/cm3, x = 5 cm; 49.1 cm of G4_AIR (1.20479e-3 g/cm3, mu/rho 0.02522 cm2/g) on the path.
# The formulas Geant4 11.4.2 option 0 uses give 0.04433 cm2/g: Bethe-Heitler pair parameterisation 0.02593
# (XCOM 0.02535, +2.3%, within its documented < 5%), empirical Klein-Nishina Compton 0.01740 (XCOM 0.01749),
# Livermore photoelectric ~ XCOM 0.00099. So XCOM tests the physics (loosely, 4%) and the Geant4 value
# tests that the transport in this package reproduces the implemented cross sections (3 sigma, ~0.3%).
XCOM=0.04382
G4MODEL=0.04433
NGAMMA=$(awk '/^\/run\/beamOn/ {print $2}' "$RES/transmission.mac")
mu_rho() {  # <csv> -> "count mu/rho sigma"
  awk -F, -v N="$NGAMMA" '!/^#/ {n = $4} END {
    T = n / N; air = 0.02522 * 1.20479e-3 * 49.1
    printf "%d %.6f %.6f\n", n, (-log(T) - air) / (11.35 * 5), sqrt((1 - T) / (N * T)) / (11.35 * 5) }' "$1"
}
check_mu() {  # <label> <mu> <sigma>
  echo "      $1: mu/rho = $2 +- $3 cm2/g;" \
       "XCOM $XCOM (ratio $(awk -v m="$2" -v r=$XCOM 'BEGIN {printf "%.4f", m / r}'));" \
       "Geant4 formulas $G4MODEL (pull $(awk -v m="$2" -v s="$3" -v r=$G4MODEL 'BEGIN {printf "%+.2f", (m - r) / s}') sigma)"
  awk -v m="$2" -v r=$XCOM 'BEGIN {exit !(m / r > 0.96 && m / r < 1.04)}' \
    && pass "$1 attenuation within 4% of NIST XCOM" || fail "$1 attenuation differs from NIST XCOM by more than 4%"
  awk -v m="$2" -v s="$3" -v r=$G4MODEL 'BEGIN {exit !((m - r) * (m - r) <= 9 * s * s)}' \
    && pass "$1 attenuation within 3 sigma of Geant4's cross sections" || fail "$1 attenuation differs from Geant4's cross sections"
}
mkdir -p native && cd native || exit 1
run transmission.log transmission.mac
cd "$WORK" || exit 1
read -r n1 mu1 s1 <<< "$(mu_rho native/transmission.csv)"
echo "      native: $n1 of $NGAMMA photons uncollided"
check_mu native "$mu1" "$s1"

echo "== 4. GDML round trip (export the B2 geometry, read it back)"
mkdir -p gdml && cd gdml || exit 1
printf '/run/initialize\n/persistency/gdml/write b2.gdml\n' > export.mac
run export.log export.mac
run transmission.log -g b2.gdml transmission.mac
read -r n2 mu2 s2 <<< "$(mu_rho transmission.csv)"
echo "      GDML: $n2 of $NGAMMA photons uncollided"
check_mu GDML "$mu2" "$s2"
awk -v a="$mu1" -v b="$mu2" -v s1="$s1" -v s2="$s2" 'BEGIN {d = a - b; exit !(d * d <= 9 * (s1 * s1 + s2 * s2))}' \
  && pass "GDML and native attenuation agree within 3 sigma" || fail "GDML and native attenuation differ"
events_with_hits() {  # <log>: printed events with at least one tracker hit
  sed -nE 's/.* ([0-9]+) hits stored in this event.*/\1/p' "$1" | awk '$1 > 0 {h++} END {print h + 0}'
}
hits=$(events_with_hits transmission.log)
[ "$hits" -gt 0 ] && pass "tracker hits in GDML chambers ($hits printed events with hits)" || fail "no tracker hits with GDML geometry"
# Chambers found only through <auxiliary auxtype="SensDet"/> (renamed, so the "Chamber_LV" lookup cannot match)
awk '{gsub(/Chamber_LV/, "TaggedChamber")} /<volume name="TaggedChamber/ {f = 1}
     f && /<\/volume>/ {print "      <auxiliary auxtype=\"SensDet\" auxvalue=\"Tracker\"/>"; f = 0} {print}' b2.gdml > b2_tagged.gdml
run tagged.log -g b2_tagged.gdml smoke.mac
hits=$(events_with_hits tagged.log)
[ "$hits" -gt 0 ] && pass "tracker hits in SensDet-tagged GDML chambers ($hits events)" || fail "no hits in SensDet-tagged GDML chambers"
cd "$WORK" || exit 1

if [ "${1:-}" = "--data-usage" ]; then
  echo "== 5. Which bundled data is used (information only)"
  # Run smoke.mac against a symlinked copy of the data directory with one entry masked; the bundle is
  # not modified. "missing": entry removed; "empty": dataset replaced by an empty directory (tests whether
  # its files are read, or only its presence is checked). "NEEDED": the run fails or reports more
  # G4Exception warnings than with all data present.
  base_warnings=$(grep -c 'WWWW ------- G4Exception-START' smoke.log)
  mask_run() {  # <path relative to data/> <missing|empty>
    local d s n
    rm -rf datamask && mkdir datamask
    for d in "$RES"/data/*; do
      n=$(basename "$d")
      if [[ "$1" == "$n"/* ]]; then  # mask one subdirectory of this dataset
        mkdir "datamask/$n"
        for s in "$d"/*; do [ "$n/$(basename "$s")" = "$1" ] || ln -s "$s" "datamask/$n/"; done
      elif [ "$n" = "$1" ]; then
        [ "$2" = empty ] && mkdir "datamask/$n"
      else
        ln -s "$d" datamask/
      fi
    done
    if GEANT4_DATA_DIR="$WORK/datamask" "$EXE" smoke.mac > mask.log 2>&1 \
       && ! grep -q 'EEEE ------- G4Exception-START' mask.log \
       && [ "$(grep -c 'WWWW ------- G4Exception-START' mask.log)" -le "$base_warnings" ]; then
      printf '      %-36s %-8s not used\n' "$1" "$2"
    else
      printf '      %-36s %-8s NEEDED   %s\n' "$1" "$2" "$(grep -m1 -A2 'G4Exception :' mask.log | tail -n 1)"
    fi
  }
  for d in "$RES"/data/*; do
    mask_run "$(basename "$d")" missing
    mask_run "$(basename "$d")" empty
    case "$(basename "$d")" in G4EMLOW*) for s in "$d"/*; do [ -d "$s" ] && mask_run "$(basename "$d")/$(basename "$s")" missing; done ;; esac
  done
  rm -rf datamask
fi

echo
if [ "$fails" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "$fails CHECK(S) FAILED"; fi
exit "$fails"
