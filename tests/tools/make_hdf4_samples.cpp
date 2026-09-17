// GeoReader HDF4 sample generator.
//
// Creates two minimal but genuine HDF4 files so the GDAL HDF4/HDF4Image
// drivers and the GeoReader multidimensional import can be validated without
// downloading third party sample data:
//
//   <output>/synthetic_elevation.hdf       scientific data set (MFHDF SD API),
//                                          variable /elevation, int16, 128x128
//   <output>/synthetic_hdf4_image.hdf      8-bit raster image (DF API / RI8)
//
// Build (from a developer prompt, release triplet example):
//   cmake -S . -B build -DGEOREADER_BUILD_TESTS=ON [other -D options]
//   cmake --build build --target GeoReaderHdf4SampleGenerator
//
// The target is optional: it is only configured when GEOREADER_BUILD_TESTS is
// enabled and the HDF4 development files are available.
#include <hdf.h>
#include <mfhdf.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr int kRows = 128;
constexpr int kColumns = 128;

bool writeScientificDataSet(const std::string &path)
{
    std::vector<int16> values(static_cast<size_t>(kRows) * kColumns);
    for (int row = 0; row < kRows; ++row) {
        for (int column = 0; column < kColumns; ++column) {
            values[static_cast<size_t>(row) * kColumns + column] =
                static_cast<int16>(((row + column) % 64) * 100 - 2000);
        }
    }

    const int32 file = SDstart(path.c_str(), DFACC_CREATE);
    if (file == FAIL) {
        std::printf("SDstart failed for %s\n", path.c_str());
        return false;
    }

    const int32 dimensions[2] = {kRows, kColumns};
    const int32 dataset = SDcreate(file, "elevation", DFNT_INT16, 2,
                                   const_cast<int32 *>(dimensions));
    if (dataset == FAIL) {
        std::printf("SDcreate failed for %s\n", path.c_str());
        SDend(file);
        return false;
    }

    const int32 start[2] = {0, 0};
    const int32 edges[2] = {kRows, kColumns};
    if (SDwritedata(dataset, const_cast<int32 *>(start), nullptr,
                    const_cast<int32 *>(edges), values.data()) == FAIL) {
        std::printf("SDwritedata failed for %s\n", path.c_str());
        SDendaccess(dataset);
        SDend(file);
        return false;
    }

    char units[] = "meters";
    char longName[] = "synthetic elevation";
    int16 missingValue = -9999;
    SDsetattr(file, "units", DFNT_CHAR8, 6, units);
    SDsetattr(dataset, "long_name", DFNT_CHAR8,
              static_cast<int32>(sizeof(longName)), longName);
    SDsetattr(dataset, "missing_value", DFNT_INT16, 1, &missingValue);

    SDendaccess(dataset);
    SDend(file);

    std::printf("HDF4 data set : %s\n", path.c_str());
    std::printf("  variable    : /elevation\n");
    std::printf("  dimensions  : %d x %d\n", kRows, kColumns);
    std::printf("  data type   : DFNT_INT16\n");
    std::printf("  attributes  : units=meters, long_name=\"synthetic elevation\"\n");
    return true;
}

bool writeRasterImage(const std::string &path)
{
    std::vector<uint8> image(static_cast<size_t>(kRows) * kColumns);
    for (int row = 0; row < kRows; ++row) {
        for (int column = 0; column < kColumns; ++column) {
            image[static_cast<size_t>(row) * kColumns + column] =
                static_cast<uint8>((row * 2) % 256);
        }
    }

    if (DFR8putimage(path.c_str(), reinterpret_cast<char *>(image.data()),
                     kColumns, kRows, 0) == FAIL) {
        std::printf("DFR8putimage failed for %s\n", path.c_str());
        return false;
    }

    std::printf("HDF4 image    : %s\n", path.c_str());
    std::printf("  structure   : 8-bit raster image (DFR8 / RI8)\n");
    std::printf("  dimensions  : %d x %d\n", kRows, kColumns);
    std::printf("  data type   : uint8\n");
    return true;
}

std::string joinPath(const std::string &directory, const char *leaf)
{
    if (directory.empty()) {
        return std::string(leaf);
    }
    const char last = directory.back();
    if (last == '/' || last == '\\') {
        return directory + leaf;
    }
    return directory + "/" + leaf;
}

} // namespace

int main(int argc, char **argv)
{
    if (argc < 2) {
        std::printf("usage: GeoReaderHdf4SampleGenerator <output-directory>\n");
        return 2;
    }
    const std::string outputDirectory = argv[1];

    if (!writeScientificDataSet(
            joinPath(outputDirectory, "synthetic_elevation.hdf"))) {
        return 1;
    }
    if (!writeRasterImage(joinPath(outputDirectory, "synthetic_hdf4_image.hdf"))) {
        return 1;
    }
    return 0;
}
