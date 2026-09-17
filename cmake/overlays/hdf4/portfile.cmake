# HDF4 is required by the GDAL HDF4/HDF4Image drivers.  The vcpkg baseline
# pinned by GeoReader does not ship an hdf4 port, so the project carries this
# overlay port and installs it from .vcpkg-overlays (see
# scripts/prepare_vcpkg_overlay.py).
#
# The library is built as a shared library only: the vcpkg dynamic triplet
# convention installs the import library into lib/ and the runtime into bin/,
# which keeps the packaged GeoReader runtime self-contained.
vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO HDFGroup/hdf4
    REF hdf4.3.0
    SHA512 dd1c433a393d893744c29479c756331e677d4201bb0e89f64b846d6c5d9a4fcee64e99b4ed46a97741b55cf0917002f00d8fa2582db5570aa0d6eb202242a558
    HEAD_REF master
    PATCHES
        # HDF4 asks for the "static shared" components of ZLIB, which the
        # vcpkg zlib wrapper rejects for a dynamic zlib build
        # (ZLIB-static.cmake does not exist).  Dropping the component request
        # keeps the dynamic ZLIB discovery working.
        fix-zlib-static-component.patch
)

vcpkg_cmake_configure(
    SOURCE_PATH "${SOURCE_PATH}"
    OPTIONS
        # Only the libraries needed by GDAL are built: no command line tools,
        # no examples, no tests, no Fortran/Java bindings and no bundled
        # NetCDF-3 API (the netcdf port provides that).
        -DBUILD_SHARED_LIBS=ON
        -DBUILD_STATIC_LIBS=OFF
        -DBUILD_TESTING=OFF
        -DHDF4_BUILD_TOOLS=OFF
        -DHDF4_BUILD_NETCDF_TOOLS=OFF
        -DHDF4_ENABLE_NETCDF=OFF
        -DHDF4_BUILD_EXAMPLES=OFF
        -DHDF4_BUILD_FORTRAN=OFF
        -DHDF4_BUILD_JAVA=OFF
        -DHDF4_BUILD_DOC=OFF
        -DHDF4_ENABLE_SZIP_SUPPORT=OFF
        -DHDF4_ENABLE_DEPRECATED_SYMBOLS=ON
)

vcpkg_cmake_install()
vcpkg_copy_pdbs()

# Keep a single set of CMake export files and headers.
file(REMOVE_RECURSE
    "${CURRENT_PACKAGES_DIR}/debug/include"
    "${CURRENT_PACKAGES_DIR}/debug/share"
)

vcpkg_install_copyright(FILE_LIST "${SOURCE_PATH}/COPYING")
