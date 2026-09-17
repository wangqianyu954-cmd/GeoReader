[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidateSet("Debug", "Release", "RelWithDebInfo", "MinSizeRel")]
    [string] $Type = "Release",

    [string] $BuildDir = "build",

    [ValidateRange(0, 1024)]
    [int] $Jobs = 0,

    [switch] $CleanFirst,

    [switch] $Package,

    [ValidateSet("auto", "all", "nsis", "zip")]
    [string] $PackageFormat = "auto",

    # Windows defaults to the repository's Release-only triplet so debug
    # copies of GDAL, Mapnik and their dependencies are never compiled.
    # Pass -Triplet x64-windows to reuse an existing multi-configuration tree.
    [string] $Triplet = "",

    # Defaults to <repository>/.vcpkg-overlays and is generated on demand.
    [string] $OverlayPorts = "",

    [string[]] $CMakeArgs = @()
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($PSBoundParameters.ContainsKey("PackageFormat")) {
    $Package = $true
}

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

# CMake's FetchContent downloads (used for Qlementine) only honour the
# lowercase proxy variables, while vcpkg documents the uppercase ones.  Mirror
# the uppercase configuration so a single HTTP_PROXY/HTTPS_PROXY setting works
# for both tool chains without hard coding a proxy address.
foreach ($ProxyVariable in @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY")) {
    $LowercaseName = $ProxyVariable.ToLowerInvariant()
    $ProxyValue = [Environment]::GetEnvironmentVariable($ProxyVariable)
    if ($ProxyValue -and
        -not [Environment]::GetEnvironmentVariable($LowercaseName)) {
        Set-Item -Path "Env:$LowercaseName" -Value $ProxyValue
    }
}

$InstalledRoot = Join-Path $ProjectRoot "vcpkg_installed"
$TripletDirectory = Join-Path $ProjectRoot "cmake\triplets"
$OverlayPortsDirectory = if ($OverlayPorts) {
    [IO.Path]::GetFullPath($OverlayPorts)
} else {
    Join-Path $ProjectRoot ".vcpkg-overlays"
}

if (-not $Triplet) {
    $ReleaseTriplet = Join-Path $TripletDirectory "x64-windows-release.cmake"
    $Triplet = if (Test-Path $ReleaseTriplet) {
        "x64-windows-release"
    } else {
        "x64-windows"
    }
}

function Resolve-ProjectPath {
    param([Parameter(Mandatory)][string] $RequestedPath)

    $Candidate = if ([IO.Path]::IsPathRooted($RequestedPath)) {
        [IO.Path]::GetFullPath($RequestedPath)
    } else {
        [IO.Path]::GetFullPath((Join-Path $ProjectRoot $RequestedPath))
    }

    $ProjectPrefix = $ProjectRoot.TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    if ($Candidate -eq $ProjectRoot -or
        -not $Candidate.StartsWith(
            $ProjectPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The build directory must be inside $ProjectRoot."
    }
    return $Candidate
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string[]] $ArgumentList
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $LASTEXITCODE."
    }
}

# CMake is resolved explicitly: the Visual Studio CMake uses the Windows
# certificate store for HTTPS downloads, while GnuTLS based builds (for example
# MinGW CMake) may have no trust anchors configured and then fail to download
# FetchContent sources behind a TLS terminating proxy.  Set GEOREADER_CMAKE to
# override the discovery.
function Resolve-CMakeCommand {
    if ($env:GEOREADER_CMAKE -and (Test-Path $env:GEOREADER_CMAKE)) {
        return (Resolve-Path $env:GEOREADER_CMAKE).Path
    }

    $ProgramFilesX86 = ${env:ProgramFiles(x86)}
    if (-not $ProgramFilesX86) {
        $ProgramFilesX86 = $env:ProgramFiles
    }
    if ($ProgramFilesX86) {
        $VsWhere = Join-Path $ProgramFilesX86 `
            "Microsoft Visual Studio\Installer\vswhere.exe"
        if (Test-Path $VsWhere) {
            $VsInstallation = & $VsWhere -latest -products * `
                -property installationPath 2>$null | Select-Object -First 1
            if ($VsInstallation) {
                $VsCMake = Join-Path $VsInstallation `
                    "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
                if (Test-Path $VsCMake) {
                    return $VsCMake
                }
            }
        }
    }

    $FromPath = Get-Command cmake -ErrorAction SilentlyContinue
    if (-not $FromPath) {
        throw "Required command was not found: cmake"
    }
    return $FromPath.Source
}

# GeoReader needs two overlay ports that the pinned vcpkg baseline cannot
# provide: Mapnik 4.3.0 (the built-in port is 4.0.7) and an HDF4-enabled GDAL
# (plus the hdf4 library port itself).  They are generated from the repository
# sources instead of being committed as build output.
function Invoke-OverlayProvisioning {
    param([Parameter(Mandatory)][string] $VcpkgRoot)

    $RequiredPorts = @("mapnik", "gdal", "hdf4")
    $MissingPorts = $RequiredPorts.Where({
        -not (Test-Path (Join-Path $OverlayPortsDirectory "$_\portfile.cmake"))
    })

    $PrepareScript = Join-Path $PSScriptRoot "prepare_vcpkg_overlay.py"
    $Python = $null
    foreach ($Candidate in @("python3", "python")) {
        $Command = Get-Command $Candidate -ErrorAction SilentlyContinue
        if (-not $Command) {
            continue
        }
        # Skip the Microsoft Store placeholder executable.
        if ($Command.Source -like "*\WindowsApps\*") {
            continue
        }
        & $Command.Source --version *> $null
        if ($LASTEXITCODE -eq 0) {
            $Python = $Command
            break
        }
    }
    if (-not $Python -or -not (Test-Path $PrepareScript)) {
        if ($MissingPorts.Count -eq 0) {
            Write-Warning (
                "Keeping the existing vcpkg overlay ports in " +
                "$OverlayPortsDirectory; python3 is unavailable to refresh " +
                "them from the repository sources.")
            return
        }
        throw (
            "vcpkg overlay ports are missing in $OverlayPortsDirectory " +
            "($($MissingPorts -join ', ')) and could not be generated. " +
            "python3 and scripts/prepare_vcpkg_overlay.py are required.")
    }

    # Refresh on every build so the overlays always match the repository
    # sources (for example a patched hdf4 port).
    Write-Host "Refreshing vcpkg overlay ports in $OverlayPortsDirectory"
    & $Python.Source $PrepareScript --vcpkg-root $VcpkgRoot `
        --output $OverlayPortsDirectory
    if ($LASTEXITCODE -ne 0) {
        throw (
            "Generating the vcpkg overlay ports failed with exit code " +
            "$LASTEXITCODE.")
    }
    foreach ($Port in $RequiredPorts) {
        if (-not (Test-Path (Join-Path $OverlayPortsDirectory "$Port\portfile.cmake"))) {
            throw "The vcpkg overlay port '$Port' is still missing after generation."
        }
    }
}

foreach ($Command in @("ninja")) {
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        throw "Required command was not found: $Command"
    }
}

$CmakeCommand = Resolve-CMakeCommand
$CpackCommand = Join-Path (Split-Path -Parent $CmakeCommand) "cpack.exe"
if (-not (Test-Path $CpackCommand)) {
    $CpackCommand = "cpack"
}

$BuildPath = Resolve-ProjectPath $BuildDir

# A build directory configured against another dependency tree cannot be
# reused: its cache stores absolute paths into that other triplet, which vcpkg
# removes when it installs a different triplet.  Only the implicit default
# directory is adjusted, so an explicit -BuildDir is always honoured.
function Test-StaleBuildCache {
    param(
        [Parameter(Mandatory)][string] $CacheFile,
        [Parameter(Mandatory)][string] $ExpectedTriplet
    )

    if (-not (Test-Path $CacheFile)) {
        return $false
    }
    $MatchedLines = Select-String -Path $CacheFile `
        -Pattern 'vcpkg_installed[/\\]([^/\\";)]+)[/\\]' -AllMatches `
        -ErrorAction SilentlyContinue
    foreach ($MatchedLine in $MatchedLines) {
        foreach ($Group in $MatchedLine.Matches) {
            if ($Group.Groups[1].Value -ne $ExpectedTriplet) {
                return $true
            }
        }
    }
    return $false
}

if (-not $CleanFirst -and -not $PSBoundParameters.ContainsKey("BuildDir")) {
    $CacheFile = Join-Path $BuildPath "CMakeCache.txt"
    $CacheIsStale = Test-StaleBuildCache -CacheFile $CacheFile `
        -ExpectedTriplet $Triplet
    if ($CacheIsStale) {
        $BuildDir = "$BuildDir-$Triplet"
        $BuildPath = Resolve-ProjectPath $BuildDir
        Write-Host (
            "Build directory '$CacheFile' references another dependency " +
            "tree; using '${BuildDir}' for triplet '$Triplet' instead.")
    }
}

if ($CleanFirst) {
    & (Join-Path $PSScriptRoot "clean.ps1") -BuildDir $BuildPath
}

$ConfigureArguments = @(
    "-S", $ProjectRoot,
    "-B", $BuildPath,
    "-G", "Ninja",
    "-DCMAKE_BUILD_TYPE=$Type"
)

$HasQtPrefix = $CMakeArgs.Where({
    $_.StartsWith("-DCMAKE_PREFIX_PATH=", [StringComparison]::OrdinalIgnoreCase)
}).Count -gt 0
if (-not $HasQtPrefix -and $env:QTDIR) {
    $ConfigureArguments += "-DCMAKE_PREFIX_PATH=$env:QTDIR"
}

$HasToolchain = $CMakeArgs.Where({
    $_.StartsWith(
        "-DCMAKE_TOOLCHAIN_FILE=", [StringComparison]::OrdinalIgnoreCase)
}).Count -gt 0
if (-not $HasToolchain -and $env:VCPKG_ROOT) {
    $VcpkgRoot = [IO.Path]::GetFullPath($env:VCPKG_ROOT)
    $ConfigureArguments += @(
        "-DCMAKE_TOOLCHAIN_FILE=$(Join-Path $VcpkgRoot 'scripts\buildsystems\vcpkg.cmake')",
        "-DVCPKG_INSTALLED_DIR=$InstalledRoot",
        "-DVCPKG_TARGET_TRIPLET=$Triplet",
        "-DGEOREADER_BUNDLE_VCPKG_RUNTIME=ON",
        "-DGEOREADER_VCPKG_RUNTIME_ROOT=$(Join-Path $InstalledRoot $Triplet)"
    )

    Invoke-OverlayProvisioning -VcpkgRoot $VcpkgRoot
    $ConfigureArguments += "-DVCPKG_OVERLAY_PORTS=$OverlayPortsDirectory"
    if (Test-Path (Join-Path $TripletDirectory "$Triplet.cmake")) {
        $ConfigureArguments += "-DVCPKG_OVERLAY_TRIPLETS=$TripletDirectory"
    }

    # Offline builds can point at an unpacked Qlementine tree; FetchContent
    # then skips its download step entirely.
    $HasQlementineSource = $CMakeArgs.Where({
        $_.StartsWith(
            "-DFETCHCONTENT_SOURCE_DIR_QLEMENTINE=",
            [StringComparison]::OrdinalIgnoreCase)
    }).Count -gt 0
    if (-not $HasQlementineSource -and $env:GEOREADER_QLEMENTINE_SOURCE_DIR) {
        $ConfigureArguments +=
            "-DFETCHCONTENT_SOURCE_DIR_QLEMENTINE=$env:GEOREADER_QLEMENTINE_SOURCE_DIR"
    }
}
$ConfigureArguments += $CMakeArgs

try {
    Invoke-Checked $CmakeCommand $ConfigureArguments
} catch {
    Write-Warning (
        "Configuring the project failed. If the failure is a FetchContent " +
        "download (Qlementine), configure a proxy through HTTP_PROXY and " +
        "HTTPS_PROXY (the lowercase http_proxy/https_proxy variables are " +
        "derived automatically) or set GEOREADER_QLEMENTINE_SOURCE_DIR to an " +
        "unpacked Qlementine source directory.")
    throw
}

$BuildArguments = @("--build", $BuildPath, "--parallel")
if ($Jobs -gt 0) {
    $BuildArguments += $Jobs.ToString()
}
Invoke-Checked $CmakeCommand $BuildArguments

$Architecture = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
    "arm64"
} else {
    "x64"
}
$RuntimeDirectory =
    Join-Path $ProjectRoot "dist\runtime\Windows-$Architecture"
if (Test-Path -LiteralPath $RuntimeDirectory) {
    Remove-Item -LiteralPath $RuntimeDirectory -Recurse -Force
}
New-Item -ItemType Directory -Path $RuntimeDirectory -Force | Out-Null
$InstallArguments = @(
    "--install", $BuildPath,
    "--config", $Type,
    "--prefix", $RuntimeDirectory
)
Invoke-Checked $CmakeCommand $InstallArguments

$ExecutablePath = Join-Path $RuntimeDirectory "bin\GeoReader.exe"
Write-Host "Build completed: $(Join-Path $BuildPath 'GeoReader.exe')"
Write-Host "Runnable output preserved at: $ExecutablePath"

if (-not $Package) {
    return
}

$PackageDirectory = Join-Path $ProjectRoot "dist"
New-Item -ItemType Directory -Path $PackageDirectory -Force | Out-Null

$Generators = switch ($PackageFormat) {
    "auto" {
        if (Get-Command "makensis" -ErrorAction SilentlyContinue) {
            @("NSIS")
        } else {
            Write-Warning "NSIS was not found; creating a ZIP package instead."
            @("ZIP")
        }
    }
    "all" { @("NSIS", "ZIP") }
    "nsis" { @("NSIS") }
    "zip" { @("ZIP") }
}

foreach ($Generator in $Generators) {
    if ($Generator -eq "NSIS" -and
        -not (Get-Command "makensis" -ErrorAction SilentlyContinue)) {
        throw "NSIS packaging requires makensis (for example: choco install nsis)."
    }
    $PackageArguments = @(
        "--config", (Join-Path $BuildPath "CPackConfig.cmake"),
        "-G", $Generator,
        "-B", $PackageDirectory
    )
    Invoke-Checked $CpackCommand $PackageArguments
}

Write-Host "Windows packages completed ($($Generators -join ', ')): $PackageDirectory"
