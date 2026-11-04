#!/usr/bin/env python3
"""File types the extension handles, and the Info.plists generated from them.

usage: file_types.py exts <cad 0|1>
       file_types.py plists <cad 0|1> <system-types.txt> <min_os> <app.plist> <ext.plist> <preview.plist>
"""
import plistlib
import sys

# id, description, extensions, needs OpenCASCADE
TYPES = [
    ("com.modelthumbs.3mf", "3MF 3D Manufacturing File", "3mf", False),
    ("com.modelthumbs.amf", "AMF Additive Manufacturing File", "amf", False),
    ("com.modelthumbs.off", "OFF Mesh", "off", False),
    ("com.modelthumbs.glb", "glTF Binary Model", "glb", False),
    ("com.modelthumbs.gltf", "glTF Model", "gltf", False),
    ("com.modelthumbs.xyz", "XYZ Point Cloud", "xyz", False),
    ("com.modelthumbs.pts", "PTS Point Cloud", "pts", False),
    ("com.modelthumbs.gcode", "G-code", "gcode gco", False),
    ("com.modelthumbs.bgcode", "Binary G-code", "bgcode", False),
    ("com.modelthumbs.f3d", "Fusion Design", "f3d", False),
    ("com.modelthumbs.f3z", "Fusion Archive", "f3z", False),
    ("com.modelthumbs.ufp", "Ultimaker Format Package", "ufp", False),
    ("com.modelthumbs.fcstd", "FreeCAD Document", "fcstd FCStd", False),
    ("com.modelthumbs.sl1", "Prusa SL1 Print", "sl1 sl1s", False),
    ("com.modelthumbs.lightburn", "LightBurn Project", "lbrn lbrn2", False),
    ("com.modelthumbs.chitubox", "Chitubox Resin Print", "ctb cbddlp photon phz", False),
    ("com.modelthumbs.goo", "Elegoo / Phrozen Resin Print", "goo prz", False),
    ("com.modelthumbs.anycubic", "Anycubic Resin Print",
     "pws pw0 pwx dlp dl2p pwmx pmx2 pwmb px6s pwmo pm3n pm4n pwms pwma pmsq pm3 pm3m pm3r pm5 pm5s m5sp pwc", False),
    ("com.modelthumbs.rhino", "Rhino 3D Model", "3dm", False),
    ("com.modelthumbs.blend", "Blender File", "blend blend1", False),
    ("com.modelthumbs.skp", "SketchUp Model", "skp", False),
    ("com.modelthumbs.solidworks", "SolidWorks Document", "sldprt sldasm slddrw SLDPRT SLDASM SLDDRW", False),
    ("com.modelthumbs.inventor", "Inventor Document", "ipt iam ipn idw", False),
    ("com.modelthumbs.e57", "E57 Point Cloud", "e57", False),
    ("com.modelthumbs.pcd", "PCD Point Cloud", "pcd", False),
    ("com.modelthumbs.las", "LAS Point Cloud", "las", False),
    ("com.modelthumbs.dae", "Collada Model", "dae", False),
    ("com.modelthumbs.vrml", "VRML Model", "wrl vrml", False),
    ("com.modelthumbs.x3d", "X3D Model", "x3d", False),
    ("com.modelthumbs.3ds", "3D Studio Model", "3ds", False),
    ("com.modelthumbs.step", "STEP CAD Model", "step stp p21", True),
    ("com.modelthumbs.iges", "IGES CAD Model", "iges igs", True),
    ("com.modelthumbs.brep", "BREP CAD Model", "brep brp", True),
]
# Types macOS already defines (OBJ, PLY).
SYSTEM_TYPES = ["public.geometry-definition-format", "public.polygon-file-format"]
SYSTEM_EXTS = ["obj", "ply"]


def active(cad):
    return [t for t in TYPES if cad or not t[3]]


def exts(cad):
    found = set(SYSTEM_EXTS)
    for _, _, e, _ in active(cad):
        found.update(x.lower() for x in e.split())
    return sorted(found)


def plists(cad, types_path, min_os, app_path, ext_path, preview_path):
    with open(types_path) as f:
        extra = [line.rstrip("\n").split("\t")[1] for line in f if "\t" in line]
    types = active(cad)
    imported = [{"UTTypeIdentifier": i, "UTTypeDescription": d, "UTTypeConformsTo": ["public.data"],
                 "UTTypeTagSpecification": {"public.filename-extension": e.split()}}
                for i, d, e, _ in types]
    supported = sorted(set([t[0] for t in types] + SYSTEM_TYPES + extra))
    common = {"CFBundleDevelopmentRegion": "en", "CFBundleInfoDictionaryVersion": "6.0",
              "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1", "LSMinimumSystemVersion": min_os}
    with open(app_path, "wb") as f:
        plistlib.dump({**common, "CFBundleExecutable": "ModelThumbs", "CFBundleIdentifier": "com.modelthumbs.app",
                       "CFBundleName": "ModelThumbs", "CFBundleDisplayName": "ModelThumbs",
                       "CFBundlePackageType": "APPL", "LSApplicationCategoryType": "public.app-category.utilities",
                       "NSPrincipalClass": "NSApplication", "NSHighResolutionCapable": True,
                       "UTImportedTypeDeclarations": imported}, f)
    with open(ext_path, "wb") as f:
        plistlib.dump({**common, "CFBundleExecutable": "ModelThumbsThumbnailer",
                       "CFBundleIdentifier": "com.modelthumbs.app.thumbnailer",
                       "CFBundleName": "ModelThumbsThumbnailer", "CFBundleDisplayName": "ModelThumbs",
                       "CFBundlePackageType": "XPC!", "CFBundleSupportedPlatforms": ["MacOSX"],
                       "NSExtension": {"NSExtensionPointIdentifier": "com.apple.quicklook.thumbnail",
                                       "NSExtensionPrincipalClass": "ThumbnailProvider",
                                       "NSExtensionAttributes": {"QLSupportedContentTypes": supported,
                                                                 "QLThumbnailMinimumDimension": 0}}}, f)
    with open(preview_path, "wb") as f:
        plistlib.dump({**common, "CFBundleExecutable": "ModelThumbsPreviewer",
                       "CFBundleIdentifier": "com.modelthumbs.app.previewer",
                       "CFBundleName": "ModelThumbsPreviewer", "CFBundleDisplayName": "ModelThumbs Preview",
                       "CFBundlePackageType": "XPC!", "CFBundleSupportedPlatforms": ["MacOSX"],
                       "NSExtension": {"NSExtensionPointIdentifier": "com.apple.quicklook.preview",
                                       "NSExtensionPrincipalClass": "PreviewProvider",
                                       "NSExtensionAttributes": {"QLSupportedContentTypes": supported,
                                                                 "QLIsDataBasedPreview": True,
                                                                 "QLSupportsSearchableItems": False}}}, f)
    print(f"{len(imported)} declared types, {len(supported)} supported, {len(extra)} from this Mac")


def main():
    command, cad = sys.argv[1], sys.argv[2] == "1"
    if command == "exts":
        print(" ".join(exts(cad)))
    elif command == "plists":
        plists(cad, *sys.argv[3:8])
    else:
        sys.exit(f"unknown command: {command}")


if __name__ == "__main__":
    main()
