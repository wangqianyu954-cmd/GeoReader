from __future__ import annotations

import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from prepare_vcpkg_overlay import (  # noqa: E402
    GDAL_HDF4_FEATURE,
    MAPNIK_43_OPTIONS,
    MAPNIK_SHA512,
    MAPNIK_VERSION,
    STATIC_OVERLAY_ROOT,
    copy_static_overlays,
    prepare_gdal_overlay,
    prepare_overlay,
)

PROJECT_ROOT = Path(__file__).resolve().parents[1]

# SHA-512 of HDFGroup/hdf4 tag hdf4.3.0, verified against the upstream archive
# (<https://github.com/HDFGroup/hdf4/archive/hdf4.3.0.tar.gz>) before pinning.
HDF4_SHA512 = (
    "dd1c433a393d893744c29479c756331e677d4201bb0e89f64b846d6c5d9a4fcee64e99b4"
    "ed46a97741b55cf0917002f00d8fa2582db5570aa0d6eb202242a558"
)


class PrepareVcpkgOverlayTests(unittest.TestCase):
    def test_prepares_mapnik_43_port(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source_port = root / "vcpkg" / "ports" / "mapnik"
            source_port.mkdir(parents=True)
            (source_port / "vcpkg.json").write_text(
                json.dumps({"name": "mapnik", "version": "4.0.7"}),
                encoding="utf-8",
            )
            (source_port / "portfile.cmake").write_text(
                "vcpkg_from_github(\n"
                "    SHA512 deadbeef\n"
                ")\n"
                "vcpkg_cmake_configure(\n"
                "    OPTIONS\n"
                "        ${FEATURE_OPTIONS}\n"
                ")\n",
                encoding="utf-8",
            )

            destination = prepare_overlay(
                root / "vcpkg",
                root / "overlays",
            )
            manifest = json.loads(
                (destination / "vcpkg.json").read_text(encoding="utf-8")
            )
            portfile = (destination / "portfile.cmake").read_text(
                encoding="utf-8"
            )

            self.assertEqual(manifest["version"], MAPNIK_VERSION)
            self.assertIn(MAPNIK_SHA512, portfile)
            for option in MAPNIK_43_OPTIONS:
                self.assertIn(option, portfile)


    def test_prepares_hdf4_enabled_gdal_port(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source_port = root / "vcpkg" / "ports" / "gdal"
            source_port.mkdir(parents=True)
            (source_port / "vcpkg.json").write_text(
                json.dumps({
                    "name": "gdal",
                    "version": "3.12.4",
                    "features": {"hdf5": {"description": "Enable HDF5 support"}},
                }),
                encoding="utf-8",
            )
            (source_port / "portfile.cmake").write_text(
                "vcpkg_check_features(OUT_FEATURE_OPTIONS FEATURE_OPTIONS\n"
                "    FEATURES\n"
                "        hdf5             GDAL_USE_HDF5\n"
                "        netcdf           GDAL_USE_NETCDF\n"
                ")\n",
                encoding="utf-8",
            )

            destination = prepare_gdal_overlay(root / "vcpkg", root / "overlays")
            manifest = json.loads(
                (destination / "vcpkg.json").read_text(encoding="utf-8")
            )
            portfile = (destination / "portfile.cmake").read_text(
                encoding="utf-8"
            )

            self.assertEqual(destination.name, "gdal")
            self.assertEqual(
                manifest["features"][GDAL_HDF4_FEATURE],
                {
                    "description": "Enable HDF4 support",
                    "dependencies": [{"name": "hdf4"}],
                },
            )
            # Existing features must survive the overlay generation.
            self.assertEqual(
                manifest["features"]["hdf5"]["description"],
                "Enable HDF5 support",
            )
            self.assertIn("hdf4             GDAL_USE_HDF4", portfile)
            self.assertLess(
                portfile.index("GDAL_USE_HDF5"),
                portfile.index("GDAL_USE_HDF4"),
            )

    def test_copies_checked_in_overlay_ports(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "overlays-source" / "hdf4"
            source.mkdir(parents=True)
            (source / "portfile.cmake").write_text(
                "vcpkg_from_github()\n", encoding="utf-8")
            (source / "vcpkg.json").write_text(
                '{"name": "hdf4"}\n', encoding="utf-8")

            copied = copy_static_overlays(
                root / "overlays", root / "overlays-source")

            self.assertEqual([path.name for path in copied], ["hdf4"])
            for leaf in ("portfile.cmake", "vcpkg.json"):
                self.assertTrue((root / "overlays" / "hdf4" / leaf).is_file())

    def test_repository_hdf4_overlay_is_complete(self) -> None:
        port = PROJECT_ROOT / "cmake" / "overlays" / "hdf4"
        self.assertEqual(port, STATIC_OVERLAY_ROOT / "hdf4")

        manifest = json.loads((port / "vcpkg.json").read_text(encoding="utf-8"))
        portfile = (port / "portfile.cmake").read_text(encoding="utf-8")

        self.assertEqual(manifest["name"], "hdf4")
        self.assertEqual(manifest["version"], "4.3.0")
        for field in ("description", "homepage", "license", "supports",
                      "dependencies"):
            self.assertIn(field, manifest)
        self.assertIn("REPO HDFGroup/hdf4", portfile)
        self.assertIn("REF hdf4.3.0", portfile)
        self.assertIn(HDF4_SHA512, portfile)

        # Every referenced patch must exist, stay a valid unified diff and use
        # LF line endings so that `git apply` accepts it on every platform.
        patches = re.findall(r"(?m)^\s+([A-Za-z0-9_.-]+\.patch)\s*$", portfile)
        self.assertIn("fix-zlib-static-component.patch", patches)
        for patch in patches:
            patch_path = port / patch
            self.assertTrue(patch_path.is_file(), patch)
            content = patch_path.read_text(encoding="utf-8")
            self.assertTrue(content.startswith("diff --git "), patch)
            self.assertNotIn("\r", content, patch)


if __name__ == "__main__":
    unittest.main()
