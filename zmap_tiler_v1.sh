#!/bin/bash
{

mapid="test"
infile="era5_t2_4000x2000"

indir="tiles/Origin-Images/"
outdir="capstone_web/${mapid}/"
mkdir ${outdir}

llon=-180
rlon=180
ulat=90
llat=-90

gdal_translate -of GTiff -a_ullr ${llon} ${ulat} ${rlon} ${llat} -a_srs EPSG:4326 ${indir}${infile}.png ${indir}${infile}.tif

gdal_translate -of VRT -a_ullr ${llon} ${ulat} ${rlon} ${llat} ${indir}${infile}.tif dataset.vrt

gdal_translate -of MRF -co COMPRESS=PNG -co BLOCKSIZE=512 -r bilinear dataset.vrt ${outdir}dataset.mrf \
  && rm dataset.vrt ${indir}${infile}.tif #${outdir}${infile}.mrf.aux.xml

gdaladdo -r avg ${outdir}dataset.mrf 2 4


#/var/www/mco2.acg.maine.edu/html/capstone/test$ nano dataset.webconf


RegExp .*/tile/.*
Size <total size of raster>
PageSize <page size>
DataFile <path to data file>
IndexFile <path to index file>
SkippedLevels   <no of levels to skip>

${infile}.webconf

exit
}


# many zoom levels
#gdaladdo -r avg ${infile}.mrf 2 4 8 16 32 64 128