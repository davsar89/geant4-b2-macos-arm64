# Geant4 example B2a — portable build for Apple Silicon Macs

Geant4 11.4 basic example **B2a** (a lead target in front of a tracker of five xenon chambers)
packaged as a self-contained macOS app for **Apple Silicon (M1–M4), macOS 12 or newer**.
Nothing has to be installed: Geant4, Qt and Xerces-C are inside, and so are the physics data.

- Qt window with the **3D view** of the detector (Geant4 TSG/OpenGL viewer)
- **GDML** geometry import
- **Electromagnetic physics only** (γ, e−, e+): Geant4 standard EM option 0 — the same EM
  physics and 0.7 mm production cut as FTFP_BERT — without hadronic physics. Default beam: 3 GeV e−.

## Quick start (tester)

1. Download `exampleB2a-macos-arm64.zip` and double-click it to unzip.
2. The app is not signed with an Apple Developer ID, so macOS blocks it the first time.
   Open **Terminal** and run once (adjust the path if you unzipped elsewhere):

   ```bash
   xattr -dr com.apple.quarantine ~/Downloads/exampleB2a-macos-arm64
   ```

   (Alternative: try to open it, then System Settings → Privacy & Security → *Open Anyway*.)
3. Double-click **`exampleB2a.app`**. The Qt window opens with the B2 detector in 3D.
   Type `/run/beamOn 10` in the command box (or use the *Run* menu) to shoot 10 electrons.

From Terminal, inside the unzipped folder:

```bash
./run.command                            # same Qt window
./run.command run1.mac                   # batch run of a macro (no window)
./run.command -g detector.gdml           # Qt window with your GDML geometry
./run.command -g detector.gdml run2.mac  # batch run with your GDML geometry
./test_package.sh                        # self-test, a few minutes (see below)
```

Macros are searched first in the current directory, then inside the app
(`gui.mac init_vis.mac vis.mac run1.mac run2.mac smoke.mac transmission.mac`).

## GDML geometry

`-g file.gdml` replaces the built-in B2 geometry.

- Name the world logical volume `World` and make it a box, so the gun starts at the world's −z face
  and shoots along +z. Otherwise B2 warns at every event and fires from the origin.
- Volumes named `Chamber_LV`, or tagged as below, become tracker chambers. Their hits are
  printed like B2's hits, with the physvol `copynumber` as chamber number:

  ```xml
  <volume name="MyChamber">
    ...
    <auxiliary auxtype="SensDet" auxvalue="Tracker"/>
  </volume>
  ```
- Export the current geometry with `/persistency/gdml/write file.gdml` (after `/run/initialize`).
- Schema validation is off (XML parsing works offline).

## What is inside

```
exampleB2a-macos-arm64/
├── exampleB2a.app/
│   └── Contents/
│       ├── MacOS/exampleB2a          arm64 executable: Geant4, CLHEP, Xerces-C, expat, zlib linked statically
│       ├── Frameworks/, PlugIns/     Qt 6 (dynamic libraries, bundled)
│       └── Resources/
│           ├── *.mac                 macros
│           └── data/                 G4EMLOW8.8 (EM part), G4ENSDFSTATE3.0, PhotonEvaporation6.1.2
├── run.command
├── test_package.sh
├── BUILD_INFO.txt                    exact versions, flags, data sizes
└── licenses/
```

Only the data that EM physics needs is bundled — no hadronic cross sections:

- **G4EMLOW 8.8**, without `dna microelec dpwa JAEAESData msc_GS` (611 of 697 MB). Those directories
  belong to physics this binary does not contain (Geant4-DNA, MicroElec, option-4 and
  Livermore/Penelope multiple scattering).
- **G4ENSDFSTATE 3.0** (2 MB): Geant4's nuclide table reads it at `/run/initialize`, even for EM-only runs.
- **PhotonEvaporation 6.1.2** (42 MB): since Geant4 11.4.2, every EM constructor
  (`G4EmBuilder` → `G4NuclearLevelData` → `G4LevelReader`) stops the program at start-up if this
  directory is missing. `test_package.sh` reports whether its files are actually read. The app finds its data inside the bundle through
`GEANT4_DATA_DIR`; if you set `GEANT4_DATA_DIR` or `G4LEDATA` yourself, your value is used.

## Self-test

`test_package.sh` runs on any Apple Silicon Mac and checks:

1. The executable is arm64 and depends only on macOS system libraries and the bundled Qt.
2. `run1.mac` (materials, 0.2 T field, step limit, e−/e+) and `smoke.mac` run cleanly with only
   the bundled data.
3. **Physics:** the fraction of 6 MeV photons that cross the 5 cm lead target without interacting
   gives μ/ρ(Pb, 6 MeV), with a statistical error of about 0.3 % (200 000 photons). It must agree
   - within 4 % with NIST XCOM (0.04382 cm²/g, without coherent scattering), and
   - within 3σ with 0.04433 cm²/g, the value from the formulas Geant4 11.4.2 implements.

   The two references differ because Geant4's parameterised pair-production cross section is 2.3 %
   above XCOM at 6 MeV. That is within its documented accuracy (< 5 %). CI measures
   0.04447 ± 0.00013 cm²/g: 1.5 % above XCOM and 1.1σ from Geant4's own formulas. So the transport
   in this package reproduces the implemented physics.
4. **GDML:** the B2 geometry is written to GDML, read back with `-g`, and must give the same
   attenuation and tracker hits (CI: identical photon counts).
5. `--data-usage` (information only): which bundled datasets and G4EMLOW subdirectories the physics
   actually reads. Geant4 aborts on purpose here, so macOS shows "quit unexpectedly" dialogs.

## How it is built

Everything is built by [`build_mac.sh`](build_mac.sh) on GitHub Actions (`macos-15` runner),
then tested by `test_package.sh` on fresh `macos-15` and `macos-26` runners that have no Geant4,
Qt or Xerces ([workflow](.github/workflows/macos-arm64.yml)). Versions are pinned in
[`versions.env`](versions.env):

- Geant4 11.4.2, static libraries, multithreaded, Qt + GDML
- Qt 6.9.3 (official binaries), bundled with `macdeployqt`
- Xerces-C 3.3.0, static, no network access
- Deployment target macOS 12.0, arm64 only

The same script builds the package on any Apple Silicon Mac with Xcode ≥ 16, CMake and python3:
`./build_mac.sh` (about an hour the first time).

`B2a/` is `examples/basic/B2/B2a` from Geant4 11.4.2 with these changes: EM-only physics list,
e− beam, `-g` GDML option, bundle data/macro paths, command-based scoring enabled, EM particles
in the GUI menu, and two check macros (`smoke.mac`, `transmission.mac`).

## Licences

Geant4 (Geant4 Software License), Qt 6 (LGPL v3, dynamically linked, frameworks replaceable in
`Contents/Frameworks`; source at https://download.qt.io/archive/qt/6.9/6.9.3/) and Xerces-C
(Apache 2.0). Texts in `licenses/`.
