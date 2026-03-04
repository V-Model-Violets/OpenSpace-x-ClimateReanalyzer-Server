#!/usr/bin/env bash
# translate_raster_dataset.sh — Convert a source raster into tiled MRF datasets
#                               and generate the matching AHTSE webconf files.
#
# Pipeline overview:
#   1. Convert the input raster to a plain RGB GeoTIFF.
#   2. Build a binary alpha mask (white where any RGB channel is non-zero).
#   3. Merge RGB + mask into a 4-band RGBA GeoTIFF.
#   4. Compress the RGBA TIF into MRF (PNG tiles, 512 px blocks) for two
#      dataset variants: Bmng and Gebco.
#   5. Add reduced-resolution overview levels so AHTSE can serve zoom-outs.
#   6. Write matching .webconf files declaring raster size, tile layout, and
#      file paths.
#   7. Re-run genconf.sh so ahtse.conf is kept in sync, then restart Apache.
#
# Usage: $0 <input_raster> <DatasetName>
#   input_raster  — any GDAL-supported raster file.
#   DatasetName   — logical name for the dataset (used as directory prefix).
#
# Example: $0 ~/images/world.tif ClimateReanalysis
set -euo pipefail

# Require exactly two positional arguments
if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <input_raster> <DatasetName>"
  exit 1
fi

INPUT="$1"
DATASET="$2"

# Locate the repository root relative to this script's location
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ ! -f "${INPUT}" ]; then
  echo "Input raster not found: ${INPUT}"
  exit 1
fi

# Extract filename components for intermediate file naming
NAME="$(basename "${INPUT}")"
EXT="${NAME##*.}"
BASENAME="${NAME%.*}"

# Create output directories for data and webconf files for both dataset variants
mkdir -p "${REPO_ROOT}/data/${DATASET}"
mkdir -p "${REPO_ROOT}/data/${DATASET}/Bmng"
mkdir -p "${REPO_ROOT}/data/${DATASET}/Gebco"

mkdir -p "${REPO_ROOT}/webconf/${DATASET}/Bmng"
mkdir -p "${REPO_ROOT}/webconf/${DATASET}/Gebco"

# Intermediate file paths used throughout the pipeline
RGB_TIF="${REPO_ROOT}/data/${DATASET}/${BASENAME}_rgb.tif"    # 3-band RGB copy
MASK_TIF="${REPO_ROOT}/data/${DATASET}/${BASENAME}_mask.tif"  # 1-band alpha mask
ALPHA_TIF="${REPO_ROOT}/data/${DATASET}/${BASENAME}_rgba.tif" # Final 4-band RGBA

# Step 1: Convert the raw input to a standard 3-band GeoTIFF.
# Many source formats (HDF, NetCDF, etc.) are not directly usable downstream.
if [ ! -f "${RGB_TIF}" ]; then
  gdal_translate -of GTiff "${INPUT}" "${RGB_TIF}"
fi

# Step 2: Build a binary alpha mask.
# Pixels are fully opaque (255) wherever at least one RGB channel is non-zero,
# and transparent (0) where all three channels are black (typically no-data areas).
if [ ! -f "${MASK_TIF}" ]; then
  gdal_calc.py \
    -A "${RGB_TIF}" --A_band=1 \
    -B "${RGB_TIF}" --B_band=2 \
    -C "${RGB_TIF}" --C_band=3 \
    --calc="((A + B + C) > 0) * 255" \
    --outfile="${MASK_TIF}" \
    --NoDataValue=0 \
    --type=Byte
fi

# Step 3: Combine the RGB image and the alpha mask into a single 4-band RGBA TIF.
# gdal_merge -separate stacks each input as a new band rather than spatially merging.
if [ ! -f "${ALPHA_TIF}" ]; then
  gdal_merge.py -separate -o "${ALPHA_TIF}" "${RGB_TIF}" "${MASK_TIF}"
fi

# Step 4a: Compress to MRF for the Bmng dataset variant.
# MRF (Meta Raster Format) is the tile format AHTSE/mod_mrf reads natively.
# BLOCKSIZE=512 sets the tile dimension; PNG compression is lossless.
gdal_translate -of MRF -co COMPRESS=PNG -co BLOCKSIZE=512 "${ALPHA_TIF}" "${REPO_ROOT}/data/${DATASET}/Bmng/bmng.mrf"

# Step 5a: Build overview pyramid for Bmng (factors 2, 4, 8, 16, 32, 64).
# 'average' resampling gives smooth results for photographic rasters.
gdaladdo -r average "${REPO_ROOT}/data/${DATASET}/Bmng/bmng.mrf" 2 4 8 16 32 64

# Step 4b/5b: Same MRF conversion and overviews for the Gebco dataset variant.
gdal_translate -of MRF -co COMPRESS=PNG -co BLOCKSIZE=512 "${ALPHA_TIF}" "${REPO_ROOT}/data/${DATASET}/Gebco/gebco.mrf"
gdaladdo -r average "${REPO_ROOT}/data/${DATASET}/Gebco/gebco.mrf" 2 4 8 16 32 64

# Step 6: Determine the pixel dimensions of the output raster for the webconf.
# gdalinfo prints a line like "Size is 21600, 10800" from which we extract W and H.
SIZE_LINE="$(gdalinfo "${REPO_ROOT}/data/${DATASET}/Bmng/bmng.mrf" | grep 'Size is' | head -n1)"
W="$(echo "${SIZE_LINE}" | awk '{print $3}' | tr -d ',')"
H="$(echo "${SIZE_LINE}" | awk '{print $4}' | tr -d ',')"

# Step 6a: Write the Bmng webconf that AHTSE will use for this dataset variant.
# Fields:
#   RegExp     — URL pattern mod_mrf matches to handle a request.
#   Size       — width height bands levels of the full overview pyramid.
#   PageSize   — tile width height (must match BLOCKSIZE used in gdal_translate).
#   DataFile   — absolute path to the MRF data file (.ppg = PNG-packed).
#   IndexFile  — absolute path to the MRF index file (.idx).
#   SkippedLevels — how many pyramid levels to skip (0 = use all).
cat > "${REPO_ROOT}/webconf/${DATASET}/Bmng/Bmng.webconf" <<EOC
RegExp .*/tile/.*
Size ${W} ${H} 1 7
PageSize 512 512 1 7
DataFile ${REPO_ROOT}/data/${DATASET}/Bmng/bmng.ppg
IndexFile ${REPO_ROOT}/data/${DATASET}/Bmng/bmng.idx
SkippedLevels 0
EOC

# Step 6b: Write the Gebco webconf (identical layout, separate data paths).
cat > "${REPO_ROOT}/webconf/${DATASET}/Gebco/Gebco.webconf" <<EOC
RegExp .*/tile/.*
Size ${W} ${H} 1 7
PageSize 512 512 1 7
DataFile ${REPO_ROOT}/data/${DATASET}/Gebco/gebco.ppg
IndexFile ${REPO_ROOT}/data/${DATASET}/Gebco/gebco.idx
SkippedLevels 0
EOC

# Step 7: Regenerate ahtse.conf so Apache picks up the new dataset directories,
# then restart Apache to apply the updated configuration.
cd "${REPO_ROOT}"
bash genconf.sh

service apache2 restart
