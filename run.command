#!/bin/bash
# Start example B2a from Terminal (double-clicking also works).
#   ./run.command                                  Qt window with the 3D view
#   ./run.command run1.mac                         batch run of a macro
#   ./run.command -g detector.gdml [macro.mac]     use a GDML geometry
HERE="$(cd "$(dirname "$0")" && pwd)"
exec "$HERE/exampleB2a.app/Contents/MacOS/exampleB2a" "$@"
