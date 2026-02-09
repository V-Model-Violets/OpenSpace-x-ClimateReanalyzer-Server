#!/usr/bin/env bash
set -euo pipefail

echo "AHTSE Server Setup"

HOME_DIR="${HOME}"
WMS_DIR="${HOME_DIR}/wms_modules"
MOD_DIR="${HOME_DIR}/modules"
LIB_DIR="${HOME_DIR}/lib"
INC_DIR="${HOME_DIR}/include"

APACHE_MODS_AVAIL="/etc/apache2/mods-available"
APACHE_MODS_EN="/etc/apache2/mods-enabled"

echo "Installing dependencies..."
sudo apt-get update
sudo apt-get install -y apache2 apache2-dev gdal-bin libgdal-dev build-essential gcc g++ git cmake pkg-config autoconf automake libtool

echo "Creating directories..."
mkdir -p "${WMS_DIR}" "${MOD_DIR}" "${LIB_DIR}" "${INC_DIR}"

echo "Configuring dynamic linker to find user libraries..."
echo "${LIB_DIR}" | sudo tee /etc/ld.so.conf.d/capstone-ahtse.conf >/dev/null
sudo ldconfig

echo "Cloning required dependencies..."
cd "${WMS_DIR}"
for repo in libahtse AHTSE libicd mod_mrf mod_receive mod_sfim mod_reproject mod_convert; do
  if [ -d "${repo}" ]; then
    echo "Repository ${repo} already exists. Skipping..."
  else
    git clone "https://github.com/lucianpls/${repo}.git"
  fi
done

ensure_lcl() {
  local d="$1"
  if [ -f "${d}/Makefile.lcl.example" ] && [ ! -f "${d}/Makefile.lcl" ]; then
    cp "${d}/Makefile.lcl.example" "${d}/Makefile.lcl"
  fi
}

build_make_repo() {
  local name="$1"
  local dir="$2"
  echo "Building ${name} (make) in ${dir}..."
  cd "${dir}"
  ensure_lcl "${dir}"
  make
  make install
}

build_cmake_repo() {
  local name="$1"
  local repo_dir="$2"
  echo "Building ${name} (cmake) in ${repo_dir}..."
  cd "${repo_dir}"
  mkdir -p build
  cd build
  cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="${HOME_DIR}" ..
  make -j"$(nproc)"
  make install
}

build_repo_smart() {
  local name="$1"
  local repo_dir="${WMS_DIR}/${name}"

  echo "Building ${name}..."
  if [ ! -d "${repo_dir}" ]; then
    echo "ERROR: Repo directory not found: ${repo_dir}" >&2
    exit 1
  fi

  if [ -f "${repo_dir}/src/Makefile" ] || [ -f "${repo_dir}/src/makefile" ] || [ -f "${repo_dir}/src/Makefile.lcl.example" ]; then
    build_make_repo "${name}" "${repo_dir}/src"
    return
  fi

  if [ -f "${repo_dir}/Makefile" ] || [ -f "${repo_dir}/makefile" ] || [ -f "${repo_dir}/Makefile.lcl.example" ]; then
    build_make_repo "${name}" "${repo_dir}"
    return
  fi

  if [ -f "${repo_dir}/CMakeLists.txt" ]; then
    build_cmake_repo "${name}" "${repo_dir}"
    return
  fi

  echo "ERROR: No recognized build files for ${name} in ${repo_dir}" >&2
  (ls -la "${repo_dir}" || true) >&2
  exit 1
}

# Build order matters
build_repo_smart "mod_receive"
build_repo_smart "libicd"
build_repo_smart "libahtse"

# mod_mrf: custom Makefile.lcl
echo "Building mod_mrf (custom Makefile.lcl)..."
MRF_DIR="${WMS_DIR}/mod_mrf/src"
cd "${MRF_DIR}"
cat << 'MRF_MAKE' > Makefile.lcl
APXS = apxs
PREFIX ?= $(HOME)
includedir = $(shell $(APXS) -q includedir 2>/dev/null)
EXTRA_INCLUDES = $(shell $(APXS) -q EXTRA_INCLUDES 2>/dev/null)
EXTRA_INCLUDES += -I../../libahtse/src
EXTRA_INCLUDES += -I../../libicd/src
EXTRA_INCLUDES += -I../../mod_receive/src
LIBTOOL = $(shell $(APXS) -q LIBTOOL 2>/dev/null)
LIBEXECDIR = $(shell $(APXS) -q libexecdir 2>/dev/null)
EXP_INCLUDEDIR = $(PREFIX)/include
CP = cp
DEST = $(PREFIX)/modules
MRF_MAKE
make
make install

build_repo_smart "mod_convert"
build_repo_smart "mod_reproject"
build_repo_smart "mod_sfim"

echo "Refreshing dynamic linker cache..."
sudo ldconfig

echo "Locating libicd.so..."
LIBICD_PATH="${LIB_DIR}/libicd.so"
if [ ! -f "${LIBICD_PATH}" ]; then
  echo "ERROR: Expected ${LIBICD_PATH} but it does not exist." >&2
  echo "Find it with: find '${HOME_DIR}' -maxdepth 4 -name 'libicd.so*' -print" >&2
  exit 1
fi
echo "-> libicd found at: ${LIBICD_PATH}"

echo "Verifying libahtse dependency resolution..."
if [ -f "${MOD_DIR}/libahtse.so" ]; then
  ldd "${MOD_DIR}/libahtse.so" | grep -E 'not found|libicd' || true
else
  echo "ERROR: ${MOD_DIR}/libahtse.so not found" >&2
  exit 1
fi

echo "Installing Apache module load files..."
install_mod_load() {
  local name="$1"
  local contents="$2"
  local avail="${APACHE_MODS_AVAIL}/${name}.load"
  local enabled="${APACHE_MODS_EN}/${name}.load"

  echo "${contents}" | sudo tee "${avail}" >/dev/null
  if [ ! -e "${enabled}" ]; then
    sudo ln -s "${avail}" "${enabled}"
  fi
}

# Load dependency first
install_mod_load "mrf" "LoadFile ${LIBICD_PATH}
LoadFile ${MOD_DIR}/libahtse.so
LoadModule mrf_module ${MOD_DIR}/mod_mrf.so"

install_mod_load "convert" "LoadFile ${LIBICD_PATH}
LoadFile ${MOD_DIR}/libahtse.so
LoadModule convert_module ${MOD_DIR}/mod_convert.so"

install_mod_load "receive" "LoadModule receive_module ${MOD_DIR}/mod_receive.so"
install_mod_load "retile"  "LoadModule retile_module ${MOD_DIR}/mod_retile.so"
install_mod_load "sfim"    "LoadModule sfim_module ${MOD_DIR}/mod_sfim.so"

echo "Creating OpenSpace web directory..."
sudo mkdir -p /var/www/capstone
sudo chown -R www-data:www-data /var/www/capstone

echo "Installing OpenSpace virtual host..."
sudo tee /etc/apache2/sites-available/001-capstone.conf >/dev/null << 'APACHE'
<VirtualHost *:80>
    ServerName capstone.maps
    DocumentRoot /var/www/capstone

    <Directory /var/www/capstone>
        Options +Indexes
        Require all granted
        AllowOverride None
    </Directory>

    ErrorLog ${APACHE_LOG_DIR}/capstone-error.log
    CustomLog ${APACHE_LOG_DIR}/capstone-access.log combined
</VirtualHost>
APACHE

if [ ! -e /etc/apache2/sites-enabled/001-capstone.conf ]; then
  sudo ln -s /etc/apache2/sites-available/001-capstone.conf /etc/apache2/sites-enabled/001-capstone.conf
fi

echo "Testing Apache configuration..."
sudo apache2ctl configtest

echo "Restarting Apache..."
sudo systemctl restart apache2

echo "Apache status:"
sudo systemctl status apache2 --no-pager

echo "AHTSE server install complete!"