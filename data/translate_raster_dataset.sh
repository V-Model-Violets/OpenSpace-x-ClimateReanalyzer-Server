#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <input_raster> <DatasetName>"
  exit 1
fi

INPUT="$1"
DATASET="$2"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ ! -f "${INPUT}" ]; then
  echo "Input raster not found: ${INPUT}"
  exit 1
fi

NAME="$(basename "${INPUT}")"
EXT="${NAME##*.}"
BASENAME="${NAME%.*}"

mkdir -p "${REPO_ROOT}/data/${DATASET}"
mkdir -p "${REPO_ROOT}/data/${DATASET}/Bmng"
mkdir -p "${REPO_ROOT}/data/${DATASET}/Gebco"

mkdir -p "${REPO_ROOT}/webconf/${DATASET}/Bmng"
mkdir -p "${REPO_ROOT}/webconf/${DATASET}/Gebco"

RGB_TIF="${REPO_ROOT}/data/${DATASET}/${BASENAME}_rgb.tif"
MASK_TIF="${REPO_ROOT}/data/${DATASET}/${BASENAME}_mask.tif"
ALPHA_TIF="${REPO_ROOT}/data/${DATASET}/${BASENAME}_rgba.tif"

if [ ! -f "${RGB_TIF}" ]; then
  gdal_translate -of GTiff "${INPUT}" "${RGB_TIF}"
fi

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

if [ ! -f "${ALPHA_TIF}" ]; then
  gdal_merge.py -separate -o "${ALPHA_TIF}" "${RGB_TIF}" "${MASK_TIF}"
fi

gdal_translate -of MRF -co COMPRESS=PNG -co BLOCKSIZE=512 "${ALPHA_TIF}" "${REPO_ROOT}/data/${DATASET}/Bmng/bmng.mrf"
gdaladdo -r average "${REPO_ROOT}/data/${DATASET}/Bmng/bmng.mrf" 2 4 8 16 32 64

gdal_translate -of MRF -co COMPRESS=PNG -co BLOCKSIZE=512 "${ALPHA_TIF}" "${REPO_ROOT}/data/${DATASET}/Gebco/gebco.mrf"
gdaladdo -r average "${REPO_ROOT}/data/${DATASET}/Gebco/gebco.mrf" 2 4 8 16 32 64

SIZE_LINE="$(gdalinfo "${REPO_ROOT}/data/${DATASET}/Bmng/bmng.mrf" | grep 'Size is' | head -n1)"
W="$(echo "${SIZE_LINE}" | awk '{print $3}' | tr -d ',')"
H="$(echo "${SIZE_LINE}" | awk '{print $4}' | tr -d ',')"

cat > "${REPO_ROOT}/webconf/${DATASET}/Bmng/Bmng.webconf" <<EOC
RegExp .*/tile/.*
Size ${W} ${H} 1 7
PageSize 512 512 1 7
DataFile ${REPO_ROOT}/data/${DATASET}/Bmng/bmng.ppg
IndexFile ${REPO_ROOT}/data/${DATASET}/Bmng/bmng.idx
SkippedLevels 0
EOC

cat > "${REPO_ROOT}/webconf/${DATASET}/Gebco/Gebco.webconf" <<EOC
RegExp .*/tile/.*
Size ${W} ${H} 1 7
PageSize 512 512 1 7
DataFile ${REPO_ROOT}/data/${DATASET}/Gebco/gebco.ppg
IndexFile ${REPO_ROOT}/data/${DATASET}/Gebco/gebco.idx
SkippedLevels 0
EOC

cd "${REPO_ROOT}"
bash genconf.sh

service apache2 restart
