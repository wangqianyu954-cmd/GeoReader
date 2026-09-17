#!/usr/bin/env python3

"""Prepare the project-local vcpkg overlay ports used by GeoReader.

The vcpkg baseline pinned by GeoReader ships Mapnik 4.0.7 (which no longer
compiles against the GDAL version the project uses) and no HDF4 port at all,
so the build installs Mapnik 4.3.0 and an HDF4-enabled GDAL through overlay
ports.  The generated ports live in a git-ignored directory (``.vcpkg-overlays``
by default) and are consumed through ``VCPKG_OVERLAY_PORTS``.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
from pathlib import Path

MAPNIK_VERSION = "4.3.0"
MAPNIK_SHA512 = (
    "fc76b1bddee8f9828db0d2ea6239caae14f8539ce95cd28d42662f207adf01d0"
    "7c1d9de4c7db86e559a22ee30b5a5713b39ee9d28b0178ddfb17a87f19237877"
)

# Mapnik 4.3 增加了若干默认开启的可选组件。GeoReader 只需要 GDAL/OGR、
# GeoJSON、Raster 和 Shape，显式关闭其余新组件可避免引入无关依赖。
MAPNIK_43_OPTIONS = (
    "-DUSE_AVIF=OFF",
    "-DBUILD_SHARED_PLUGINS=ON",
    "-DUSE_PLUGIN_INPUT_GDAL_OGR=ON",
    "-DUSE_PLUGIN_INPUT_POSTGIS_PGRASTER=OFF",
    "-DUSE_PLUGIN_INPUT_TILES=OFF",
    "-DUSE_PLUGIN_INPUT_TILES_SSL=OFF",
)

# Overlay ports that are checked into the repository instead of being
# generated from a vcpkg port (vcpkg has no hdf4 port at the pinned baseline).
STATIC_OVERLAY_ROOT = Path(__file__).resolve().parents[1] / "cmake" / "overlays"

# The pinned GDAL port has no "hdf4" feature either, so the overlay port adds
# one and maps it to GDAL's GDAL_USE_HDF4 switch.
GDAL_HDF4_FEATURE = "hdf4"
GDAL_HDF4_FEATURE_ANCHOR = "        hdf5             GDAL_USE_HDF5\n"
GDAL_HDF4_FEATURE_OPTION = "        hdf4             GDAL_USE_HDF4\n"


def prepare_overlay(vcpkg_root: Path, output_root: Path) -> Path:
    source_port = vcpkg_root.resolve() / "ports" / "mapnik"
    if not (source_port / "portfile.cmake").is_file():
        raise FileNotFoundError(f"Mapnik vcpkg port was not found: {source_port}")

    destination = output_root.resolve() / "mapnik"
    if destination.exists():
        shutil.rmtree(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source_port, destination)

    manifest_path = destination / "vcpkg.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["version"] = MAPNIK_VERSION
    manifest.pop("version-string", None)
    manifest.pop("port-version", None)
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    portfile_path = destination / "portfile.cmake"
    portfile = portfile_path.read_text(encoding="utf-8")
    portfile, replacement_count = re.subn(
        r"(?m)^(\s*SHA512\s+)[0-9a-fA-F]+$",
        rf"\g<1>{MAPNIK_SHA512}",
        portfile,
        count=1,
    )
    if replacement_count != 1:
        raise RuntimeError("Could not replace the Mapnik source SHA-512")

    feature_marker = "        ${FEATURE_OPTIONS}\n"
    if feature_marker not in portfile:
        raise RuntimeError("Could not locate Mapnik vcpkg CMake feature options")
    if MAPNIK_43_OPTIONS[0] not in portfile:
        extra_options = "".join(f"        {option}\n" for option in MAPNIK_43_OPTIONS)
        portfile = portfile.replace(
            feature_marker,
            feature_marker + extra_options,
            1,
        )
    portfile_path.write_text(portfile, encoding="utf-8")

    return destination


def prepare_gdal_overlay(vcpkg_root: Path, output_root: Path) -> Path:
    """Create the GDAL overlay port that enables the HDF4 driver."""
    source_port = vcpkg_root.resolve() / "ports" / "gdal"
    if not (source_port / "portfile.cmake").is_file():
        raise FileNotFoundError(f"GDAL vcpkg port was not found: {source_port}")

    destination = output_root.resolve() / "gdal"
    if destination.exists():
        shutil.rmtree(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source_port, destination)

    manifest_path = destination / "vcpkg.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    features = manifest.setdefault("features", {})
    features[GDAL_HDF4_FEATURE] = {
        "description": "Enable HDF4 support",
        "dependencies": [{"name": "hdf4"}],
    }
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    portfile_path = destination / "portfile.cmake"
    portfile = portfile_path.read_text(encoding="utf-8")
    if GDAL_HDF4_FEATURE_OPTION not in portfile:
        if GDAL_HDF4_FEATURE_ANCHOR not in portfile:
            raise RuntimeError("Could not locate the GDAL HDF5 feature option")
        portfile = portfile.replace(
            GDAL_HDF4_FEATURE_ANCHOR,
            GDAL_HDF4_FEATURE_ANCHOR + GDAL_HDF4_FEATURE_OPTION,
            1,
        )
        portfile_path.write_text(portfile, encoding="utf-8")

    return destination


def copy_static_overlays(
    output_root: Path,
    source_root: Path | None = None,
) -> list[Path]:
    """Copy the checked-in overlay ports (for example hdf4)."""
    static_root = (source_root or STATIC_OVERLAY_ROOT)
    prepared: list[Path] = []
    if not static_root.is_dir():
        return prepared

    for port in sorted(static_root.iterdir()):
        if not port.is_dir():
            continue
        destination = output_root.resolve() / port.name
        if destination.exists():
            shutil.rmtree(destination)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(port, destination)
        prepared.append(destination)
    return prepared


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Create GeoReader's vcpkg overlay ports."
    )
    parser.add_argument("--vcpkg-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--static-overlays",
        type=Path,
        default=None,
        help="Directory containing checked-in overlay ports "
             f"(default: {STATIC_OVERLAY_ROOT}).",
    )
    arguments = parser.parse_args()

    mapnik_port = prepare_overlay(arguments.vcpkg_root, arguments.output)
    gdal_port = prepare_gdal_overlay(arguments.vcpkg_root, arguments.output)
    static_ports = copy_static_overlays(
        arguments.output, arguments.static_overlays)

    print(f"Prepared Mapnik {MAPNIK_VERSION} overlay: {mapnik_port}")
    print(f"Prepared HDF4-enabled GDAL overlay: {gdal_port}")
    for port in static_ports:
        print(f"Copied overlay port: {port}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
