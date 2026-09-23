[CmdletBinding(DefaultParameterSetName = 'Default')]
param (
    [Parameter(Mandatory = $true, ParameterSetName = 'Default')]
    [string]$InputVrt,

    [Parameter(Mandatory = $true, ParameterSetName = 'Default')]
    [string]$OutputVrt,

    [Parameter(Mandatory = $false, ParameterSetName = 'Default')]
    [int]$TileCount = 4,

    [Parameter(Mandatory = $false, ParameterSetName = 'Default')]
    [double]$TargetRes = 1.0,

    [Parameter(Mandatory = $false, ParameterSetName = 'Default')]
    [int]$MaxCores = [Environment]::ProcessorCount,

    [Parameter(Mandatory = $false, ParameterSetName = 'Default')]
    [ValidateSet('Auto', 'Horizontal', 'Vertical')]
    [string]$TileOrientation = 'Auto',

    [Parameter(Mandatory = $false, ParameterSetName = 'Default')]
    [switch]$MaterializeMosaic,

    [Parameter(Mandatory = $true, ParameterSetName = 'Help')]
    [switch]$Help
)

if ($Help) {
    Write-Host @"
Description:
  Produces a resampled COG mosaic at TargetRes from a large raster mosaic (VRT) as
  cheaply as possible, by splitting the work into row-based tiles processed in
  parallel with GDAL.

  The goal is to avoid decoding full-resolution pixels whenever possible: for each
  tile, the script looks at the source's existing overview levels and opens the one
  whose resolution is closest to (but not coarser than) TargetRes via
  -oo OVERVIEW_LEVEL, then reads from it using a pixel-space -srcwin instead of a
  georeferenced -projwin (no coordinate round-trip, no rounding risk). Row
  boundaries between tiles are snapped to the inherited block size so two parallel
  tile jobs never decode the same straddling source block twice. If the selected
  overview's native resolution already matches TargetRes closely enough, no
  resampling is applied at all - the tile is a straight pixel copy. Otherwise, a
  light resample still runs, but only over the already-downsampled overview data,
  never over the full-resolution source.

  Output COG creation options (compression, quality, block size, photometric) are
  inherited from the first source raster referenced by the input VRT, to avoid an
  unnecessary format conversion on top of the resample. Each output tile still
  builds its own overview pyramid (-ovr AUTO), which remains the slowest step
  since it requires resampling the tile's own pixel data at every zoom level.

Usage:
  .\resample_mosaic.ps1 -InputVrt <path> -OutputVrt <path> -TileCount <int> -TargetRes <double> -MaxCores <int> -TileOrientation <Auto|Horizontal|Vertical>

Parameters:
  -InputVrt   Path to the input VRT file (required)
  -OutputVrt  Path for the final output VRT (required)
  -TileCount  Number of parallel spatial tiles to generate (default: 4)
  -TargetRes  Output pixel resolution (default: 1.0)
  -MaxCores   Total CPU cores allocated to the processing pool (default: all logical processors detected)
  -TileOrientation  Axis to split tiles along: Auto, Horizontal or Vertical (default: Auto - picks
                    whichever axis has more BlockSize units available)
  -MaterializeMosaic  Also merge the tiles into a single physical COG (<OutputVrt> with a .tif
                      extension), in addition to the lightweight VRT (default: false)
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

Write-Host "Extracting geotransform and pixel grid from $InputVrt..." -ForegroundColor Cyan
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

$PixelWidth = [double]$GeoTransform[1]
$PixelHeight = [double]$GeoTransform[5]
$SourceWidth = [int]$InfoJson.size[0]
$SourceHeight = [int]$InfoJson.size[1]

if ($PixelWidth -le 0 -or $PixelHeight -eq 0) {
    throw "Invalid pixel size in source VRT geotransform: pixel width=$PixelWidth, pixel height=$PixelHeight"
}

# Pick the source overview level closest to (but not coarser than) TargetRes, so tiles are
# read from already-decimated pixels via -oo OVERVIEW_LEVEL instead of full resolution.
$OverviewLevel = $null
$ReadWidth = $SourceWidth
$ReadHeight = $SourceHeight
$ReadPixelWidth = $PixelWidth

$SourceOverviews = @()
if ($SourceInfo.ContainsKey('bands') -and $SourceInfo['bands']) {
    foreach ($band in @($SourceInfo['bands'])) {
        if ($band.ContainsKey('overviews') -and $band['overviews']) {
            $SourceOverviews = @($band['overviews'])
            break
        }
    }
}

$SourceFullWidth = [double]$SourceInfo.size[0]
$BestRatio = $null
for ($idx = 0; $idx -lt $SourceOverviews.Count; $idx++) {
    $OvWidth = [double]$SourceOverviews[$idx]['size'][0]
    if ($OvWidth -le 0) { continue }
    $Ratio = $SourceFullWidth / $OvWidth
    $OvResX = [Math]::Abs($PixelWidth) * $Ratio
    if ($OvResX -le $TargetRes -and (-not $BestRatio -or $Ratio -gt $BestRatio)) {
        $BestRatio = $Ratio
        $OverviewLevel = $idx
    }
}

if ($null -ne $OverviewLevel) {
    $ReadWidth = [Math]::Round($SourceWidth / $BestRatio)
    $ReadHeight = [Math]::Round($SourceHeight / $BestRatio)
    $ReadPixelWidth = $PixelWidth * $BestRatio
    Write-Host "Selected source overview level $OverviewLevel (~$([Math]::Round($ReadPixelWidth, 4)) units/px) as read source for TargetRes=$TargetRes" -ForegroundColor Cyan
} else {
    Write-Host "No source overview is fine enough to cover TargetRes=$TargetRes; reading full resolution." -ForegroundColor Yellow
}

$ResTolerance = 0.001
$NeedsResample = [Math]::Abs($ReadPixelWidth - $TargetRes) -gt ($TargetRes * $ResTolerance)
if (-not $NeedsResample) {
    Write-Host "Read resolution already matches TargetRes within tolerance; skipping resample (straight pixel copy)." -ForegroundColor Cyan
}

$OutputDir = Split-Path -Path $OutputVrt -Parent
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = (Get-Location).Path
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$SplitAxis = switch ($TileOrientation) {
    'Horizontal' { 'Y' }
    'Vertical'   { 'X' }
    default {
        # Auto: split along whichever axis has more BlockSize units available, so tiles stay
        # closer to square and TileCount isn't needlessly capped by the shorter dimension.
        $WidthUnits = [Math]::Floor($ReadWidth / $BlockSize)
        $HeightUnits = [Math]::Floor($ReadHeight / $BlockSize)
        if ($WidthUnits -gt $HeightUnits) { 'X' } else { 'Y' }
    }
}
$SplitLength = if ($SplitAxis -eq 'X') { $ReadWidth } else { $ReadHeight }
Write-Host "Splitting along the $SplitAxis axis ($SplitLength px, BlockSize=$BlockSize, TileOrientation=$TileOrientation)" -ForegroundColor Cyan

# Internal boundaries are snapped to the nearest multiple of BlockSize so adjacent tile jobs
# never need to decode the same straddling source block twice.
$SplitBoundaries = New-Object 'object[]' ($TileCount + 1)
$SplitBoundaries[0] = 0
$SplitBoundaries[$TileCount] = $SplitLength
for ($k = 1; $k -lt $TileCount; $k++) {
    $Raw = ($k * $SplitLength) / $TileCount
    $SplitBoundaries[$k] = [int]([Math]::Round($Raw / $BlockSize) * $BlockSize)
}

$OutputBaseName = [System.IO.Path]::GetFileNameWithoutExtension($OutputVrt)

$TileDefs = @()
$GeneratedTiles = @()

for ($i = 0; $i -lt $TileCount; $i++) {
    $TileStart = [int]$SplitBoundaries[$i]
    $TileEnd = [int]$SplitBoundaries[$i + 1]

    if ($TileEnd -le $TileStart) {
        throw "Tile partitioning produced a zero-size tile at index $i after block alignment. Reduce TileCount or check BlockSize ($BlockSize)."
    }

    $TileFile = Join-Path $OutputDir "${OutputBaseName}_Tile_$($i + 1).tif"

    if ($SplitAxis -eq 'X') {
        $Xoff = $TileStart
        $Yoff = 0
        $Xsize = $TileEnd - $TileStart
        $Ysize = $ReadHeight
    } else {
        $Xoff = 0
        $Yoff = $TileStart
        $Xsize = $ReadWidth
        $Ysize = $TileEnd - $TileStart
    }

    $TileDefs += [pscustomobject]@{
        Tile  = $TileFile
        Xoff  = $Xoff
        Yoff  = $Yoff
        Xsize = $Xsize
        Ysize = $Ysize
    }
    $GeneratedTiles += $TileFile
}

Write-Host "Processing $TileCount tiles concurrently..." -ForegroundColor Cyan

$Jobs = foreach ($Box in $TileDefs) {
    Start-ThreadJob -ScriptBlock {
        param($Vrt, $Tile, $Xoff, $Yoff, $Xsize, $Ysize, $OverviewLevel, $NeedsResample, $Res, $Compression, $BlockSize, $Quality, $Threads)

        $tileargs = @('--config', 'GDAL_NUM_THREADS', "$Threads")

        if ($null -ne $OverviewLevel) {
            $tileargs += @('-oo', "OVERVIEW_LEVEL=$OverviewLevel")
        }

        $tileargs += @(
            '-of', 'COG',
            '-b', '1',
            '-b', '2',
            '-b', '3',
            '-srcwin', [string]$Xoff, [string]$Yoff, [string]$Xsize, [string]$Ysize,
            '-co', "COMPRESS=$Compression",
            '-co', "BLOCKSIZE=$BlockSize",
            '-co', "OVERVIEW_COMPRESS=$Compression",
            '-co', "NUM_THREADS=$Threads",
            '-co', 'BIGTIFF=YES',
            '-ovr', 'AUTO'
        )

        if ($NeedsResample) {
            $tileargs += @('-tr', [string]$Res, [string]$Res, '-r', 'average')
        }

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
    } -ArgumentList $InputVrt, $Box.Tile, $Box.Xoff, $Box.Yoff, $Box.Xsize, $Box.Ysize, $OverviewLevel, $NeedsResample, $TargetRes, $Compression, $BlockSize, $Quality, $ThreadsPerTile
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

if ($MaterializeMosaic) {
    $FinalMosaic = [System.IO.Path]::ChangeExtension($OutputVrt, '.tif')
    Write-Host "Materializing final mosaic: $FinalMosaic..." -ForegroundColor Cyan

    $mergeArgs = @(
        '--config', 'GDAL_NUM_THREADS', "$MaxCores",
        '-of', 'COG',
        '-co', "COMPRESS=$Compression",
        '-co', "BLOCKSIZE=$BlockSize",
        '-co', "OVERVIEW_COMPRESS=$Compression",
        '-co', "NUM_THREADS=$MaxCores",
        '-co', 'BIGTIFF=YES',
        '-ovr', 'AUTO'
    )

    if ($Quality) {
        $mergeArgs += @('-co', "QUALITY=$Quality")
    }

    $mergeArgs += @($OutputVrt, $FinalMosaic)

    Write-Host "[COMMAND] gdal_translate $($mergeArgs -join ' ')" -ForegroundColor DarkCyan
    & gdal_translate @mergeArgs
    if ($LASTEXITCODE -ne 0) {
        throw "gdal_translate failed to materialize final mosaic (exit code $LASTEXITCODE)"
    }
    Write-Host "[OK] Final mosaic generated: $FinalMosaic" -ForegroundColor Green
}

Write-Host "Done! Generated $OutputVrt using $TileCount tiles." -ForegroundColor Green