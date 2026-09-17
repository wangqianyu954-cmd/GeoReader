# 测试工具

本目录存放仅在需要时使用的测试辅助程序，它们不属于应用运行时的组成部分。

## `make_hdf4_samples.cpp`

生成两个最小但**真实**的 HDF4 文件，用于验证 GDAL 的 `HDF4`/`HDF4Image`
驱动以及 GeoReader 的多维数据导入流程（无需下载第三方样例数据）：

| 文件 | 生成方式 | 结构 | 变量 | 维度 | 类型 |
| --- | --- | --- | --- | --- | --- |
| `synthetic_elevation.hdf` | HDF4 MFHDF SD API | 科学数据集（SDS） | `/elevation`（`units=meters`） | 128 × 128 | `DFNT_INT16` |
| `synthetic_hdf4_image.hdf` | HDF4 DF API（`DFR8putimage`） | 8 位光栅影像（RI8） | `Raster Image #0` | 128 × 128 | `uint8` |

### 构建与使用

该目标**不是普通构建的一部分**：只有显式打开测试选项，并且确实能找到 HDF4
开发文件（`hdf.h`、`mfhdf`、`hdf`/`df`）时才会配置。

```bash
cmake -S . -B build -DGEOREADER_BUILD_TESTS=ON \
  -DCMAKE_TOOLCHAIN_FILE=<vcpkg>/scripts/buildsystems/vcpkg.cmake \
  -DVCPKG_TARGET_TRIPLET=x64-windows-release \
  -DVCPKG_OVERLAY_PORTS="$PWD/.vcpkg-overlays"
cmake --build build --target GeoReaderHdf4SampleGenerator
./build/GeoReaderHdf4SampleGenerator <output-directory>
```

生成器只接受一个输出目录参数，不依赖任何本机固定路径；运行它时需要 HDF4
运行库（`hdf`/`mfhdf` 动态库）位于 `PATH` 上：

```powershell
$env:PATH = "<vcpkg-root>\installed\x64-windows-release\bin;" + $env:PATH
.\build\GeoReaderHdf4SampleGenerator .\samples
```

随后用生成的文件验证读取流程：

```powershell
GeoReader.exe .\samples\synthetic_elevation.hdf
```
