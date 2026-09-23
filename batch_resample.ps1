[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$InputVrt = "C:\Temp\trabalhos\ortos2025\mosaic.vrt",

    [Parameter(Mandatory = $false)]
    [string]$OutputVrt = "C:\Temp\trabalhos\ortos2025\resampled_final.vrt",

    [Parameter(Mandatory = $false)]
    [int]$TileCount = 4,

    [Parameter(Mandatory = $false)]
    [double]$TargetRes = 1.0,

    [Parameter(Mandatory = $false)]
    [int]$MaxCores = [Environment]::ProcessorCount,

    [Parameter(Mandatory = $false)]
    [switch]$Help
)

if ($Help) {
    Write-Host @"
Description:
  Resamples a large raster mosaic (VRT) to a target pixel resolution by splitting it
  into row-based tiles, resampling each tile to COG in parallel using GDAL, and then
  rebuilding a single final VRT from the resulting tiles. COG creation options
  (compression, quality, block size, photometric) are inherited from the first source
  raster referenced by the input VRT. The objective is to use the Fast-Path: copy from 
  the nearest overview level present in the original vrt, and also avoid recalculations 
  as much as possible - that's why we use the same image params as the originals.

Usage:
  .\resample_mosaic.ps1 -InputVrt <path> -OutputVrt <path> -TileCount <int> -TargetRes <double> -MaxCores <int>

Parameters:
  -InputVrt   Path to the input VRT file (default: C:\Temp\trabalhos\ortos2025\mosaic.vrt)
  -OutputVrt  Path for the final output VRT (default: C:\Temp\trabalhos\ortos2025\resampled_final.vrt)
  -TileCount  Number of parallel spatial tiles to generate (default: 4)
  -TargetRes  Output pixel resolution (default: 1.0)
  -MaxCores   Total CPU cores allocated to the processing pool (default: all logical processors detected)
  -Help       Show this help message

Example:
  .\resample_mosaic.ps1 -InputVrt input.vrt -OutputVrt output.vrt -TileCount 4 -TargetRes 1.0 -MaxCores 16
"@ -ForegroundColor Yellow
    exit 0
}

if (-not (Test-Path -LiteralPath $InputVrt -PathType Leaf)) {
    throw "Input VRT not found: $InputVrt"
}

if ($TileCount -le 0) {
    throw "TileCount must be greater than zero."
}

if ($TargetRes -le 0) {
    throw "TargetRes must be greater than zero."
}

if ($MaxCores -le 0) {
    throw "MaxCores must be greater than zero."
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

foreach ($cmd in @("gdalinfo", "gdalwarp", "gdalbuildvrt")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "Required GDAL command not found on PATH: $cmd"
    }
}

function Get-JsonValueCaseInsensitive {
    param(
        $Node,
        [string[]]$Keys
    )

    if ($null -eq $Node) {
        return $null
    }

    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($key in $Node.Keys) {
            if ($Keys -contains $key) {
                return $Node[$key]
            }

            $value = Get-JsonValueCaseInsensitive -Node $Node[$key] -Keys $Keys
            if ($null -ne $value) {
                return $value
            }
        }
        return $null
    }

    if ($Node -is [System.Collections.IEnumerable] -and -not ($Node -is [string])) {
        foreach ($item in $Node) {
            $value = Get-JsonValueCaseInsensitive -Node $item -Keys $Keys
            if ($null -ne $value) {
                return $value
            }
        }
    }

    return $null
}

$ThreadsPerTile = [Math]::Max(1, [Math]::Floor($MaxCores / $TileCount))
Write-Host "System Cores Allocated: $MaxCores | Concurrent Tiles: $TileCount | Threads/Tile: $ThreadsPerTile" -ForegroundColor Cyan

Write-Host "Extracting extent and pixel grid from $InputVrt..." -ForegroundColor Cyan
if (-not [System.IO.Path]::IsPathRooted($InputVrt)) {
    $InputVrt = (Resolve-Path -LiteralPath $InputVrt).Path
}

$InfoJson = & gdalinfo -json $InputVrt | ConvertFrom-Json -AsHashTable

$VrtDir = Split-Path -Path $InputVrt -Parent
if ([string]::IsNullOrWhiteSpace($VrtDir)) {
    $VrtDir = (Get-Location).Path
}

$SourceRaster = $null
[xml]$VrtXml = Get-Content -LiteralPath $InputVrt -Raw
$SourceCandidates = @($VrtXml.SelectNodes('//*[local-name()="SourceFilename"]') | ForEach-Object { $_.InnerText } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

foreach ($CandidateFile in $SourceCandidates) {
    $CandidatePath = $CandidateFile
    if (-not [System.IO.Path]::IsPathRooted($CandidatePath)) {
        $CandidatePath = Join-Path $VrtDir $CandidatePath
    }

    if (Test-Path -LiteralPath $CandidatePath -PathType Leaf) {
        $SourceRaster = $CandidatePath
        break
    }
}

if (-not $SourceRaster -and $InfoJson.ContainsKey('files') -and $InfoJson['files']) {
    foreach ($CandidateFile in @($InfoJson['files'])) {
        if ([string]::IsNullOrWhiteSpace($CandidateFile)) {
            continue
        }
        if ($CandidateFile -ieq $InputVrt) {
            continue
        }

        $CandidatePath = $CandidateFile
        if (-not [System.IO.Path]::IsPathRooted($CandidatePath)) {
            $CandidatePath = Join-Path $VrtDir $CandidatePath
        }

        if (Test-Path -LiteralPath $CandidatePath -PathType Leaf) {
            $SourceRaster = $CandidatePath
            break
        }
    }
}

if (-not $SourceRaster) {
    throw "Unable to locate a source raster referenced by the input VRT: $InputVrt"
}

if (-not [System.IO.Path]::IsPathRooted($SourceRaster)) {
    $SourceRaster = (Resolve-Path -LiteralPath $SourceRaster).Path
}

Write-Host "Using source raster metadata from: $SourceRaster" -ForegroundColor Cyan
$SourceInfo = & gdalinfo -json $SourceRaster | ConvertFrom-Json -AsHashTable

$CompressionRaw = [string](Get-JsonValueCaseInsensitive -Node $SourceInfo -Keys @('COMPRESSION', 'compression'))
if (-not $CompressionRaw) {
    $CompressionRaw = [string](Get-JsonValueCaseInsensitive -Node $SourceInfo -Keys @('COMPRESS', 'compress'))
}
if (-not $CompressionRaw) {
    $CompressionRaw = 'DEFLATE'
}

if ($CompressionRaw -match 'JPEG') {
    $Compression = 'JPEG'
} elseif ($CompressionRaw -match 'DEFLATE') {
    $Compression = 'DEFLATE'
} elseif ($CompressionRaw -match 'LZW') {
    $Compression = 'LZW'
} elseif ($CompressionRaw -match 'ZSTD') {
    $Compression = 'ZSTD'
} elseif ($CompressionRaw -match 'PACKBITS') {
    $Compression = 'PACKBITS'
} else {
    $Compression = $CompressionRaw.Trim()
}

$Quality = [string](Get-JsonValueCaseInsensitive -Node $SourceInfo -Keys @('JPEG_QUALITY', 'jpeg_quality', 'QUALITY', 'quality'))
if ([string]::IsNullOrWhiteSpace($Quality)) {
    $Quality = $null
}

$Photometric = [string](Get-JsonValueCaseInsensitive -Node $SourceInfo -Keys @('PHOTOMETRIC', 'photometric'))
if ($Photometric) {
    $Photometric = $Photometric.ToUpperInvariant()
}

$BlockX = $null
$BlockY = $null
if ($SourceInfo.ContainsKey('bands') -and $SourceInfo['bands']) {
    foreach ($band in @($SourceInfo['bands'])) {
        if ($band.ContainsKey('block') -and $band['block']) {
            $BlockX = [int]$band['block'][0]
            $BlockY = [int]$band['block'][1]
            break
        }
    }
}

if (-not $BlockX -or -not $BlockY) {
    $BlockX = [int](Get-JsonValueCaseInsensitive -Node $SourceInfo -Keys @('BLOCKXSIZE', 'blockxsize'))
    $BlockY = [int](Get-JsonValueCaseInsensitive -Node $SourceInfo -Keys @('BLOCKYSIZE', 'blockysize'))
}

if (-not $BlockX -or -not $BlockY) {
    $BlockSize = 512
} else {
    $BlockSize = [int][Math]::Min([double]$BlockX, [double]$BlockY)
    if ($BlockSize -le 0) {
        $BlockSize = 512
    }
}

Write-Host "Inherited COG settings: COMPRESS=$Compression QUALITY=$Quality BLOCKSIZE=$BlockSize PHOTOMETRIC=$Photometric" -ForegroundColor Cyan

$GeoTransform = $InfoJson.geoTransform
if (-not $GeoTransform -or $GeoTransform.Count -lt 6) {
    throw "The input VRT does not expose a valid geotransform: $InputVrt"
}

$OriginX = [double]$GeoTransform[0]
$OriginY = [double]$GeoTransform[3]
$PixelWidth = [double]$GeoTransform[1]
$PixelHeight = [double]$GeoTransform[5]
$SourceWidth = [int]$InfoJson.size[0]
$SourceHeight = [int]$InfoJson.size[1]

if ($PixelWidth -le 0 -or $PixelHeight -eq 0) {
    throw "Invalid pixel size in source VRT geotransform: pixel width=$PixelWidth, pixel height=$PixelHeight"
}

$XMin = $OriginX
$XMax = $OriginX + ($SourceWidth * $PixelWidth)
$YMin = $OriginY + ($SourceHeight * $PixelHeight)
$YMax = $OriginY

$OutputDir = Split-Path -Path $OutputVrt -Parent
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = (Get-Location).Path
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$TileDefs = @()
$GeneratedTiles = @()

for ($i = 0; $i -lt $TileCount; $i++) {
    $TileRowStart = [Math]::Floor(($i * $SourceHeight) / $TileCount)
    $TileRowEnd = if ($i -eq ($TileCount - 1)) { $SourceHeight } else { [Math]::Floor((($i + 1) * $SourceHeight) / $TileCount) }

    if ($TileRowEnd -le $TileRowStart) {
        throw "Tile partitioning produced a zero-height tile at index $i. Reduce TileCount or check raster size."
    }

    $TileYUpper = $OriginY + ($TileRowStart * $PixelHeight)
    $TileYLower = $OriginY + ($TileRowEnd * $PixelHeight)
    $TileFile = Join-Path $OutputDir "tile_$($i + 1).tif"

    $TileDefs += [pscustomobject]@{
        Tile = $TileFile
        Ulx = $XMin
        Uly = $TileYUpper
        Lrx = $XMax
        Lry = $TileYLower
    }
    $GeneratedTiles += $TileFile
}

Write-Host "Processing $TileCount tiles concurrently..." -ForegroundColor Cyan

$Jobs = foreach ($Box in $TileDefs) {
    Start-ThreadJob -ScriptBlock {
        param($Vrt, $Tile, $Ulx, $Uly, $Lrx, $Lry, $Res, $Compression, $BlockSize, $Quality, $Threads)

        $tileargs = @(
            '--config', 'GDAL_NUM_THREADS', "$Threads",
            '-of', 'COG',
            '-b', '1',
            '-b', '2',
            '-b', '3',
            '-tr', [string]$Res, [string]$Res,
            '-projwin', [string]$Ulx, [string]$Uly, [string]$Lrx, [string]$Lry,
            '-r', 'average',
            '-co', "COMPRESS=$Compression",
            '-co', "BLOCKSIZE=$BlockSize",
            '-co', "OVERVIEW_COMPRESS=$Compression",
            '-co', "NUM_THREADS=$Threads",
            '-co', 'BIGTIFF=YES',
            '-ovr', 'AUTO'
        )

        if ($Quality) {
            $tileargs += @('-co', "QUALITY=$Quality")
        }

        $tileargs += @($Vrt, $Tile)

        Write-Host "[COMMAND] gdal_translate $($tileargs -join ' ')" -ForegroundColor DarkCyan
        & gdal_translate @tileargs
        if ($LASTEXITCODE -ne 0) {
            throw "gdal_translate failed for $Tile (exit code $LASTEXITCODE)"
        }
        Write-Host "[OK] Tile generated: $Tile" -ForegroundColor Green
    } -ArgumentList $InputVrt, $Box.Tile, $Box.Ulx, $Box.Uly, $Box.Lrx, $Box.Lry, $TargetRes, $Compression, $BlockSize, $Quality, $ThreadsPerTile
}

$Jobs | Receive-Job -Wait -AutoRemoveJob

Write-Host "Building final VRT: $OutputVrt..." -ForegroundColor Cyan
$fileList = Join-Path $OutputDir "tile_list.txt"
$GeneratedTiles | Set-Content -Path $fileList -Encoding UTF8
$finalArgs = @('-overwrite', '-input_file_list', $fileList, $OutputVrt)
Write-Host "[COMMAND] gdalbuildvrt $($finalArgs -join ' ')" -ForegroundColor DarkCyan
& gdalbuildvrt @finalArgs
if ($LASTEXITCODE -ne 0) {
    throw "gdalbuildvrt failed (exit code $LASTEXITCODE)"
}
Write-Host "[OK] Final VRT generated: $OutputVrt" -ForegroundColor Green

Write-Host "Done! Generated $OutputVrt using $TileCount tiles." -ForegroundColor Green