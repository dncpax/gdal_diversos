# ============================================================================== 
# Parallel Orthophoto COG Generator with Vector Masking
# ==============================================================================

[CmdletBinding()]
param(
    [string]$SourceDir,
    [string]$OutputDir,
    [string]$Shapefile,
    [string]$LayerName,
    [ValidateSet("rgb", "irg")]
    [string]$Photometric,
    [ValidateRange(1, 64)]
    [int]$MaxJobs,
    [switch]$Help
)

# ------------------------------------------------------------------------------

$ErrorActionPreference = "Stop"

function Show-Usage {
        Write-Host @"
Usage:
    .\batch_process_cogs.ps1 -SourceDir <folder> -OutputDir <folder> -Shapefile <file> -LayerName <name> -Photometric <rgb|irg> -MaxJobs <1-64>

Required parameters:
    -SourceDir    Folder containing source TIFF files
    -OutputDir    Folder for generated COG files
    -Shapefile    Vector mask shapefile
    -LayerName    Shapefile layer name
    -Photometric  Output band order: rgb (1,2,3) or irg (4,1,2)
    -MaxJobs      Number of parallel workers, from 1 to 64

Examples:
    .\batch_process_cogs.ps1 -SourceDir G:\Ortofotos -OutputDir C:\Temp\rgb -Shapefile C:\Temp\Limite.shp -LayerName Limite -Photometric rgb -MaxJobs 3
    .\batch_process_cogs.ps1 -SourceDir G:\Ortofotos -OutputDir C:\Temp\irg -Shapefile C:\Temp\Limite.shp -LayerName Limite -Photometric irg -MaxJobs 3
"@ -ForegroundColor Yellow
}

if ($Help) {
        Show-Usage
        exit 0
}

$missingParameters = @(
        if ([string]::IsNullOrWhiteSpace($SourceDir)) { "SourceDir" }
        if ([string]::IsNullOrWhiteSpace($OutputDir)) { "OutputDir" }
        if ([string]::IsNullOrWhiteSpace($Shapefile)) { "Shapefile" }
        if ([string]::IsNullOrWhiteSpace($LayerName)) { "LayerName" }
        if ([string]::IsNullOrWhiteSpace($Photometric)) { "Photometric" }
        if (-not $PSBoundParameters.ContainsKey("MaxJobs")) { "MaxJobs" }
)

if ($missingParameters.Count -gt 0) {
    Write-Host "[ERROR] Missing required parameter(s): $($missingParameters -join ', ')" -ForegroundColor Red
        Show-Usage
        exit 2
}

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "This script requires PowerShell 7 or later because it uses ForEach-Object -Parallel."
}

if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) {
    throw "Source directory does not exist: $SourceDir"
}

if (-not (Test-Path -LiteralPath $Shapefile -PathType Leaf)) {
    throw "Shapefile does not exist: $Shapefile"
}

if ([string]::IsNullOrWhiteSpace($LayerName)) {
    $LayerName = [IO.Path]::GetFileNameWithoutExtension($Shapefile)
}

$env:SDK_ROOT = "C:\GDAL\release-1944-x64-gdal-3-12-mapserver-8-6"
$GdalBinPath = Join-Path $env:SDK_ROOT 'bin'

# Only add the SDK-specific bin dirs if not already on PATH.
if ($env:PATH -notlike "*$GdalBinPath*") {
    $env:PATH += ";$GdalBinPath;$($GdalBinPath + '\gdal\apps');$($GdalBinPath + '\proj9\apps')"
}
#tb definir outras vars necessarias
$env:GDAL_DATA = Join-Path $GdalBinPath 'gdal-data'
$env:GDAL_DRIVER_PATH = Join-Path $GdalBinPath 'gdal\plugins'
$env:PROJ_LIB = Join-Path $GdalBinPath 'proj9\SHARE'

$env:GDAL_CACHEMAX                = "4096"
$env:GDAL_NUM_THREADS             = "ALL_CPUS"
$env:VSI_CACHE                    = "TRUE"
$env:VSI_CACHE_SIZE               = "50000000"
$env:GDAL_DISABLE_READDIR_ON_OPEN = "EMPTY_DIR"
$env:CPL_VSIL_CURL_ALLOWED_EXTENSIONS = ".tif,.tiff,.ovr"
$env:CPL_VSIL_USE_CACHE           = "YES"
$env:GDAL_MAX_DATASET_POOL_SIZE   = "800"

foreach ($commandName in @("gdal_create", "gdal_rasterize", "gdalbuildvrt", "gdal_translate")) {
    if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
        throw "GDAL command was not found on PATH: $commandName"
    }
}

# Ensure output directory exists
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# Get all source TIF files
$TifFiles = @(Get-ChildItem -LiteralPath $SourceDir -File |
    Where-Object { $_.Extension -ieq ".tif" })

if ($TifFiles.Count -eq 0) {
    Write-Warning "No TIFF files found in $SourceDir"
    exit 0
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Starting processing of $($TifFiles.Count) files..." -ForegroundColor Cyan
Write-Host " Running $MaxJobs parallel worker threads" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$Results = $TifFiles | ForEach-Object -Parallel {
    # Import variables into thread scope
    $outDir   = $using:OutputDir
    $shp      = $using:Shapefile
    $layer    = $using:LayerName
    $photometric = $using:Photometric

    $file = $_
    $baseName = $file.BaseName
    
    # Paths for temporary and final outputs
    $maskTif   = Join-Path $outDir "mask_$baseName.tif"
    $stackedVrt= Join-Path $outDir "stacked_alfa_$baseName.vrt"
    $finalCog  = Join-Path $outDir "${baseName}_${photometric}.tif"

    $outputBands = if ($photometric -eq "irg") {
        @("-b", "4", "-b", "1", "-b", "2")
    }
    else {
        @("-b", "1", "-b", "2", "-b", "3")
    }

    Write-Host "[START] Processing: $($file.Name)" -ForegroundColor Yellow

    try {
        function Invoke-Gdal {
            param(
                [string]$Command,
                [string[]]$Arguments,
                [string]$StepLabel
            )

            Write-Host "[STEP] $StepLabel [$Command $($Arguments -join ' ')]" -ForegroundColor DarkCyan
            & $Command @Arguments 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "$Command failed with exit code $LASTEXITCODE during step: $StepLabel"
            }
            Write-Host "[OK] $StepLabel" -ForegroundColor DarkGreen
        }

        if (Test-Path -LiteralPath $finalCog) {
            Remove-Item -LiteralPath $finalCog -Force
        }

        # 1. Create empty 1-band mask matched to source TIF geometry
        Invoke-Gdal "gdal_create" @("-if", $file.FullName, "-bands", "1", "-burn", "0", "-ot", "Byte", "-co", "COMPRESS=DEFLATE", $maskTif) "Create mask"

        # 2. Burn opaque (255) pixels inside shapefile boundary
        Invoke-Gdal "gdal_rasterize" @("-burn", "255", "-l", $layer, $shp, $maskTif) "Rasterize mask"

        # 3. Stack original RGB bands with generated mask band into a VRT
        Invoke-Gdal "gdalbuildvrt" @("-separate", $stackedVrt, $file.FullName, $maskTif) "Build VRT"

        # 4. Export the selected 3-band COG with band 5 as the internal mask.
        # The source contains four bands; the generated mask is band five.
        Invoke-Gdal "gdal_translate" @(
            "-of", "COG"
            $outputBands
            "-mask", "5",
            "-co", "COMPRESS=JPEG", "-co", "QUALITY=80", "-co", "RESAMPLING=AVERAGE",
            "-co", "OVERVIEW_COMPRESS=JPEG", "-co", "OVERVIEW_QUALITY=80",
            "-co", "OVERVIEWS=AUTO", "-co", "BLOCKSIZE=256",
            $stackedVrt, $finalCog
        ) "Create COG"

        Write-Host "[DONE] Finished: $baseName" -ForegroundColor Green
        [pscustomobject]@{ Name = $file.Name; Success = $true; Error = $null }
    }
    catch {
        Write-Host "[ERROR] Failed processing $baseName : $_" -ForegroundColor Red
        [pscustomobject]@{ Name = $file.Name; Success = $false; Error = $_.Exception.Message }
    }
    finally {
        if (Test-Path -LiteralPath $maskTif) {
            Remove-Item -LiteralPath $maskTif -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $stackedVrt) {
            Remove-Item -LiteralPath $stackedVrt -Force -ErrorAction SilentlyContinue
        }
    }

} -ThrottleLimit $MaxJobs

$Failed = @($Results | Where-Object { -not $_.Success })
Write-Host "`n==========================================================" -ForegroundColor Green
if ($Failed.Count -eq 0) {
    Write-Host " All $($TifFiles.Count) files processed successfully!" -ForegroundColor Green
}
else {
    Write-Host " Completed with $($Failed.Count) failure(s) out of $($TifFiles.Count) files." -ForegroundColor Red
    $Failed | ForEach-Object { Write-Host " - $($_.Name): $($_.Error)" -ForegroundColor Red }
}
Write-Host "==========================================================" -ForegroundColor Green

if ($Failed.Count -gt 0) {
    exit 1
}