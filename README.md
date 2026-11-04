# ModelThumbs

**Finder thumbnails for 3D printing, CAD and 3D scanning files on macOS.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-lightgrey)

macOS shows a preview icon for `.stl` files, but most other model formats get a generic
document icon. ModelThumbs is a Quick Look thumbnail extension that adds real previews for
**70+ file extensions**: 3MF projects, STEP parts, OBJ meshes, point cloud scans, resin
printer files, G-code, and the native files of SolidWorks, Fusion, Rhino, SketchUp, Blender
and more.

It works like the built-in STL previews. Finder draws the icons by itself whenever it needs
them, in every view (icons, columns, gallery, Get Info) and in Quick Look. Nothing runs in
the background and there's nothing to re-run when you add files.

- **Native and lightweight:** written in Swift. Models are drawn by a small built-in
  renderer, so no GPU or 3D engine is needed.
- **Private:** everything happens on your Mac. No network access, no accounts.
- **Free to build:** needs only Apple's free Command Line Tools. No Xcode, no Apple
  Developer account, no App Store.

---

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Supported file types](#supported-file-types)
- [Settings](#settings)
- [Troubleshooting](#troubleshooting)
- [Updating](#updating)
- [Uninstalling](#uninstalling)
- [Command-line renderer](#command-line-renderer)
- [How it works](#how-it-works)
- [Known limitations](#known-limitations)
- [Project structure](#project-structure)
- [Acknowledgements](#acknowledgements)

---

## Requirements

| Requirement | Notes |
|---|---|
| macOS 13 Ventura or later | Apple Silicon (M1–M4) or Intel |
| Apple Command Line Tools | Free. Install with `xcode-select --install` |
| [Homebrew](https://brew.sh) *(optional)* | Only needed for STEP / IGES / BREP thumbnails |

---

## Installation

There is no one-line installer on purpose: piping a download into a shell runs whatever the
server sends, before anyone has read it. Each step here is separate, and `make -n <target>`
prints exactly what a step will do without running it.

```bash
git clone https://github.com/enzoballardin/model-thumbs.git
cd model-thumbs
git log -3                 # see what you're about to build
make -n build              # preview the build commands
make build                 # compile and sign into ./build
make verify                # check the bundle, test it in a sandbox
make install               # verify again, copy to ~/Applications, register the extension
```

For STEP / IGES / BREP thumbnails, install [OpenCASCADE](https://dev.opencascade.org) yourself
first. The build never installs anything for you:

```bash
brew install opencascade
make build CAD=1
```

### What each step does

| Command | What it does |
|---|---|
| `make build` | Compiles into `build/`. Uses no network and touches nothing outside `build/` |
| `make build CAD=1` | Also adds STEP / IGES / BREP, and copies the OpenCASCADE libraries into the app |
| `make verify` | Checks signatures, sandbox entitlements, linked libraries and imports, then renders `Samples/` and the malformed files in `Tests/` under `sandbox-exec` with no network |
| `make test-asan` | Runs the malformed files under AddressSanitizer |
| `make install` | Runs `verify`, then installs. Use `PREFIX=/Applications` to change the location |
| `make check-quicklook` | Asks Quick Look for real thumbnails of the samples, the way Finder does |
| `make uninstall` | Removes the installed app and unregisters the extension |

`make build` also looks up file type identifiers that apps you already have (slicers, CAD
tools) have registered on this Mac, so ModelThumbs covers those too.

### Check it's enabled

Open **System Settings → General → Login Items & Extensions → Quick Look** (on older macOS:
**Privacy & Security → Extensions → Quick Look**) and make sure **ModelThumbs** is switched on.
It's enabled automatically in most cases.

Then open a folder with your models in Finder. Icon view and gallery view show thumbnails best.

Press space on a file for a large preview. It shows the largest image stored in the file when it has
one, and renders the model when it doesn't. A 3MF whose only image is small is rendered too,
because that's sharper.

Renders of Bambu Studio and OrcaSlicer projects use the saved filament colors and show plate 1.
Hand-painted faces show the base filament color.

### About signing

macOS requires Quick Look extensions to be code-signed. Because you build ModelThumbs
yourself, it's signed for local use only. There's no Apple review, nothing to pay for, and
Gatekeeper doesn't block it since the app wasn't downloaded. The build signs ad hoc unless you
choose a certificate yourself: `make build SIGN="<identity>"`.

---

## Supported file types

There are three ways a thumbnail gets made:

- **Rendered:** the geometry is read and drawn as a shaded 3/4 view.
- **Embedded preview:** the file already contains a preview image saved by the app that
  created it, and ModelThumbs shows that image.
- **Embedded or rendered:** the embedded preview is used if present; otherwise the model
  is rendered.

### 3D printing

| Format | Extensions | Thumbnail |
|---|---|---|
| 3MF (Bambu Studio, OrcaSlicer, PrusaSlicer, Cura, MakerWorld, Printables…) | `.3mf` (incl. `.gcode.3mf`) | Embedded or rendered |
| AMF (Additive Manufacturing File) | `.amf` | Rendered |
| G-code (PrusaSlicer, OrcaSlicer, Bambu, Cura…) | `.gcode` `.gco` | Embedded preview |
| Binary G-code (Prusa) | `.bgcode` | Embedded preview |
| Ultimaker Cura package | `.ufp` | Embedded preview |

### Resin (MSLA / DLP) printer files

| Format | Extensions | Thumbnail |
|---|---|---|
| Chitubox and compatibles (incl. encrypted CTB v4) | `.ctb` `.cbddlp` `.photon` | Embedded preview |
| Phrozen (Chitubox family) | `.phz` | Embedded preview |
| Elegoo GOO (v3 and v5) | `.goo` | Embedded preview |
| Phrozen PRZ | `.prz` | Embedded preview |
| Prusa SL1 / SL1S | `.sl1` `.sl1s` | Embedded preview |
| Anycubic Photon Workshop | `.pws` `.pw0` `.pwx` `.dlp` `.dl2p` `.pwmx` `.pmx2` `.pwmb` `.px6s` `.pwmo` `.pm3n` `.pm4n` `.pwms` `.pwma` `.pmsq` `.pm3` `.pm3m` `.pm3r` `.pm5` `.pm5s` `.m5sp` `.pwc` | Embedded preview |

### CAD

| Format | Extensions | Thumbnail |
|---|---|---|
| STEP | `.step` `.stp` `.p21` | Rendered (needs OpenCASCADE) |
| IGES | `.iges` `.igs` | Rendered (needs OpenCASCADE) |
| OpenCASCADE BREP | `.brep` `.brp` | Rendered (needs OpenCASCADE) |
| Autodesk Fusion design / archive | `.f3d` `.f3z` | Embedded preview |
| SolidWorks part / assembly / drawing | `.sldprt` `.sldasm` `.slddrw` | Embedded preview |
| Autodesk Inventor part / assembly / presentation / drawing | `.ipt` `.iam` `.ipn` `.idw` | Embedded preview |
| Rhino | `.3dm` | Embedded preview |
| FreeCAD | `.FCStd` | Embedded preview |
| SketchUp | `.skp` | Embedded preview |

### 3D models and meshes

| Format | Extensions | Thumbnail |
|---|---|---|
| Wavefront OBJ | `.obj` | Rendered |
| Stanford PLY (ASCII and binary) | `.ply` | Rendered (as points if it has no faces) |
| OFF | `.off` | Rendered |
| glTF 2.0 | `.glb` `.gltf` | Rendered |
| Collada | `.dae` | Rendered |
| VRML 1.0 / 2.0 | `.wrl` `.vrml` | Rendered |
| X3D (XML) | `.x3d` | Rendered |
| 3D Studio | `.3ds` | Rendered |
| Blender | `.blend` `.blend1` | Embedded preview |

### 3D scanning and point clouds

| Format | Extensions | Thumbnail |
|---|---|---|
| ASTM E57 (terrestrial / mobile scanners) | `.e57` | Rendered as points, all scans with their poses |
| LAS (LiDAR), versions 1.0–1.4 | `.las` | Rendered as points |
| PCD (Point Cloud Library): ASCII, binary, binary_compressed | `.pcd` | Rendered as points |
| XYZ / PTS text point clouds | `.xyz` `.pts` | Rendered as points |

### Laser cutting

| Format | Extensions | Thumbnail |
|---|---|---|
| LightBurn project | `.lbrn` `.lbrn2` | Embedded preview |

### Left to macOS

**STL** and **USDZ** already get thumbnails from macOS, so ModelThumbs leaves them alone.

---

## Settings

The extension runs in a sandbox and reads its settings from its own container. Set them in
Terminal:

```bash
PREFS=~/Library/Containers/com.modelthumbs.app.thumbnailer/Data/Library/Preferences/com.modelthumbs.app.thumbnailer

# 3MF: render the actual geometry instead of the slicer's embedded preview
defaults write "$PREFS" PreferEmbedded3MFThumbnail -bool false

# Colour used for rendered models (hex)
defaults write "$PREFS" ModelColor "#E38B2C"

# Go back to the defaults
defaults delete "$PREFS"
```

Then open ModelThumbs and click **Refresh thumbnails**, or run `qlmanage -r cache`.

| Setting | Default | Effect |
|---|---|---|
| `PreferEmbedded3MFThumbnail` | `true` | Use the slicer's preview image in 3MF files when there is one |
| `ModelColor` | `#8FA8C7` (slate blue) | Base colour for rendered meshes and point clouds |

---

## Troubleshooting

**Icons didn't change**

1. Open **ModelThumbs** and click **Refresh thumbnails**. This clears the Quick Look cache
   and relaunches Finder.
2. Check that ModelThumbs is enabled in System Settings (see
   [Check it's enabled](#check-its-enabled)).
3. Confirm the extension is registered. This should print a line starting with `+`:

   ```bash
   pluginkit -m -v -i com.modelthumbs.app.thumbnailer
   ```

**Test a single file**

```bash
qlmanage -t -s 512 -o /tmp ~/path/to/model.3mf
open /tmp/model.3mf.png
```

On some macOS versions `qlmanage` never exits. If it hasn't finished after about 20 seconds,
press Ctrl+C and look at the icons in Finder instead; that's the real test.

**See why a file has no thumbnail.** The command-line renderer uses the same code as the
extension and prints the error:

```bash
/Applications/ModelThumbs.app/Contents/MacOS/modelthumbs-render ~/path/to/file.step /tmp/out.png
```

Common messages:

| Message | Meaning |
|---|---|
| `no preview image` / `no embedded preview found` | The app that saved the file didn't store a preview |
| `CAD support not built in` | Rebuild with `make build CAD=1` to add STEP / IGES |
| `zstd-compressed .blend` | See [Known limitations](#known-limitations) |
| `compressed LAZ data` | `.laz` isn't supported |

**System logs**

```bash
log show --last 5m --predicate 'process == "pkd" OR eventMessage CONTAINS "ModelThumbs"'
```

**A format stopped working after installing a slicer or CAD app.** That app may have
registered its own type identifier for the extension. Run `make build` and `make install` again; the build
detects identifiers already on your Mac and adds them.

---

## Updating

```bash
git fetch origin
git log HEAD..origin/main  # read what changed
git merge origin/main
make build                 # add CAD=1 if you use STEP / IGES
make install
```

---

## Uninstalling

From your clone:

```bash
make uninstall
```

This removes `ModelThumbs.app`, unregisters the extension, and clears the thumbnail cache.
If you installed OpenCASCADE only for ModelThumbs, you can remove it as well:

```bash
brew uninstall opencascade
```

---

## Command-line renderer

`modelthumbs-render` is installed inside the app bundle. It's useful for debugging or for
batch-exporting previews:

```bash
R=/Applications/ModelThumbs.app/Contents/MacOS/modelthumbs-render

$R part.step part.png            # 512 px
$R scan.e57 scan.png 1024        # custom size
$R plate.3mf plate.png --model   # 3MF: ignore the embedded preview, render geometry
```

It also reads `.stl` and `.asc` point clouds, which the Finder extension doesn't register.

---

## How it works

```
Finder ──► Quick Look ──► ModelThumbs extension (sandboxed)
                               │
                ┌──────────────┼──────────────────┐
                ▼              ▼                  ▼
        embedded preview   mesh / point cloud   STEP / IGES / BREP
        (PNG, JPEG, RLE,   parsers               via OpenCASCADE
         RGB565, DIB)          │                  (tessellation)
                │              └────────┬─────────┘
                │                       ▼
                │              CPU renderer: orthographic 3/4 view,
                │              z-buffer, two-light shading, outline,
                │              supersampled anti-aliasing
                ▼                       ▼
                   thumbnail image ──► Finder
```

- **The renderer runs on the CPU**, so it works inside the Quick Look sandbox and gives the
  same result on every Mac. Very large point clouds are evenly subsampled (about 3 million
  points) to keep icons fast.
- **Parsers are hand-written** for speed: a streaming XML scanner for 3MF and AMF, direct
  byte parsing for OBJ, PLY and STL, and bit-level decoding for E57.
- **STEP support** links OpenCASCADE into the extension. The build script copies the
  required libraries into the app bundle, so it doesn't depend on Homebrew at runtime.
- **Up axis:** 3MF, STL, AMF, STEP and point clouds are treated as Z-up. OBJ, glTF, VRML
  and X3D are converted from Y-up. Collada follows the file's `up_axis`.

---

## Known limitations

- **Embedded-preview formats need a stored preview.** Files written by scripts or
  converters often have none (for example FreeCAD files generated without the GUI, or
  Rhino files saved with *Save Small*). They keep the generic icon.
- **Compressed Blender files aren't supported.** Blender's optional *Compress* setting uses
  zstd, which macOS has no built-in decompressor for. Uncompressed `.blend` files work.
- **Not supported:** `.laz` (compressed LiDAR), Draco-compressed glTF, and glTF files that
  keep their geometry in a separate `.bin` file (the sandbox only allows reading the file
  being previewed).
- **Primitive shapes aren't drawn.** VRML / X3D `Box`, `Sphere`, `Cylinder` and `Cone`
  nodes are skipped; exported meshes don't use them.
- **OBJ orientation is a guess.** OBJ has no up-axis field and is assumed to be Y-up, so
  some Z-up OBJ exports appear lying on their side.
- **Proprietary formats.** Parasolid (`.x_t`), ACIS (`.sat`), FBX and OpenSCAD (`.scad`)
  aren't supported because reading them needs commercial SDKs or running the source app.
- **Very large uncompressed 3MF files** (several million triangles, with no embedded
  preview) can take a few seconds the first time their icon is drawn.

---

## Project structure

```
model-thumbs/
├── Makefile                 Build, verify, install and uninstall (preview with make -n)
├── Sources/
│   ├── Core/                Format parsers and the renderer (portable Swift)
│   │   ├── Renderer.swift         CPU rasterizer
│   │   ├── ModelLoader.swift      Extension → loader dispatch
│   │   ├── Loader3MF.swift        3MF (incl. Bambu / Orca production extension)
│   │   ├── LoaderE57.swift        E57 point clouds
│   │   ├── LoaderPreviews.swift   Embedded previews (resin, CAD apps, Blender…)
│   │   └── …
│   ├── CAD/                 OpenCASCADE bridge (C++) for STEP / IGES / BREP
│   ├── Extension/           Quick Look thumbnail provider
│   ├── Preview/             Quick Look preview provider (what space shows)
│   ├── App/                 Host app (status window, refresh button)
│   └── CLI/                 modelthumbs-render command-line tool
├── Tools/
│   ├── uticheck.swift       Finds file type identifiers already registered on this Mac
│   ├── file_types.py        File type table and Info.plist generator
│   ├── verify.py            Bundle checks and sandboxed render tests
│   ├── qlcheck.swift        Requests thumbnails through Quick Look with a time limit
│   └── bundle_dylibs.py     Copies OpenCASCADE libraries into the app bundle
├── Tests/
│   └── make_malformed.py    Malformed model files for verify.py
├── Resources/
│   └── Extension.entitlements
└── Samples/                 Small test files used by make verify
```

---

## Acknowledgements

File format details were checked against these open-source projects and test data:

- [UVtools](https://github.com/sn4k3/UVtools): resin printer file layouts
- [openNURBS](https://github.com/mcneel/opennurbs): Rhino `.3dm` preview chunks and example files
- [cadmpeg](https://github.com/cadmpeg/cadmpeg): SolidWorks and Fusion container notes, test files
- [libE57Format test data](https://github.com/asmaloney/libE57Format-test-data): E57 validation
- [OpenCASCADE](https://dev.opencascade.org): STEP / IGES / BREP tessellation (LGPL 2.1 with exception)

## License

ModelThumbs is released under the [MIT License](LICENSE).

STEP / IGES / BREP support links against [OpenCASCADE](https://dev.opencascade.org), which
is licensed under the LGPL 2.1 with an additional exception. It's installed separately
through Homebrew and copied into the app only on your own Mac when you build it.

Issues and pull requests are welcome at
[github.com/enzoballardin/model-thumbs](https://github.com/enzoballardin/model-thumbs/issues).
