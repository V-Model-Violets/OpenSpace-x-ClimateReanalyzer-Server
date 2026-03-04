#!/usr/bin/env bash
# setup-ahtse.sh — One-shot installer for the AHTSE Apache tile server stack.
#
# What it does (in order):
#   1. Installs system dependencies via apt.
#   2. Creates working directories under $HOME.
#   3. Registers $HOME/lib with the dynamic linker so shared objects are found.
#   4. Clones all required AHTSE module repos from GitHub (lucianpls).
#   5. Builds them in dependency order: mod_receive → libicd → libahtse → mod_mrf
#                                       → mod_convert → mod_reproject → mod_sfim.
#   6. Writes Apache .load files and enables each module.
#   7. Creates a virtual host and restarts Apache.
#
# Usage: bash setup-ahtse.sh
#   Run as a user with sudo privileges on a Ubuntu/Debian system.
set -euo pipefail

echo "AHTSE Server Setup"

# --- Directory layout -------------------------------------------------------
HOME_DIR="${HOME}"           # User home used as install prefix
WMS_DIR="${HOME_DIR}/wms_modules"  # Source checkouts for each AHTSE repo
MOD_DIR="${HOME_DIR}/modules"      # Compiled .so files
LIB_DIR="${HOME_DIR}/lib"          # Shared libraries (libicd.so, libahtse.so, …)
INC_DIR="${HOME_DIR}/include"      # Public headers exposed to dependents

APACHE_MODS_AVAIL="/etc/apache2/mods-available"  # Canonical location for *.load files
APACHE_MODS_EN="/etc/apache2/mods-enabled"       # Symlinked .load files Apache reads

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

# ensure_lcl DIR
# If a Makefile.lcl.example exists but no Makefile.lcl yet, copy the example
# into place so make can pick up local overrides (include paths, prefixes, etc.).
ensure_lcl() {
  local d="$1"
  if [ -f "${d}/Makefile.lcl.example" ] && [ ! -f "${d}/Makefile.lcl" ]; then
    cp "${d}/Makefile.lcl.example" "${d}/Makefile.lcl"
  fi
}

# build_make_repo NAME DIR
# Ensures a Makefile.lcl exists, then invokes 'make && make install' in DIR.
# Outputs are installed relative to the prefix defined in Makefile.lcl (usually $HOME).
build_make_repo() {
  local name="$1"
  local dir="$2"
  echo "Building ${name} (make) in ${dir}..."
  cd "${dir}"
  ensure_lcl "${dir}"
  make
  make install
}

# build_cmake_repo NAME REPO_DIR
# Configures and builds a CMake-based project, installing into $HOME_DIR.
# A 'build/' subdirectory is created inside REPO_DIR for out-of-tree compilation.
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

# build_repo_smart NAME
# Auto-selects the appropriate build system for a cloned repo:
#   1. Prefers Makefile / Makefile.lcl.example inside src/ (AHTSE convention).
#   2. Falls back to Makefile / Makefile.lcl.example in the repo root.
#   3. Falls back to CMakeLists.txt in the repo root.
# Exits with an error if none of these are found.
build_repo_smart() {
  local name="$1"
  local repo_dir="${WMS_DIR}/${name}"

  echo "Building ${name}..."
  if [ ! -d "${repo_dir}" ]; then
    echo "ERROR: Repo directory not found: ${repo_dir}" >&2
    exit 1
  fi

  # Most AHTSE modules keep their Makefile under src/
  if [ -f "${repo_dir}/src/Makefile" ] || [ -f "${repo_dir}/src/makefile" ] || [ -f "${repo_dir}/src/Makefile.lcl.example" ]; then
    build_make_repo "${name}" "${repo_dir}/src"
    return
  fi

  # Some repos have the Makefile directly in the root
  if [ -f "${repo_dir}/Makefile" ] || [ -f "${repo_dir}/makefile" ] || [ -f "${repo_dir}/Makefile.lcl.example" ]; then
    build_make_repo "${name}" "${repo_dir}"
    return
  fi

  # CMake-based repos (e.g. newer libicd releases)
  if [ -f "${repo_dir}/CMakeLists.txt" ]; then
    build_cmake_repo "${name}" "${repo_dir}"
    return
  fi

  echo "ERROR: No recognized build files for ${name} in ${repo_dir}" >&2
  (ls -la "${repo_dir}" || true) >&2
  exit 1
}

# Build order matters: each library must be installed before dependents compile.
#   mod_receive  — must come first; libahtse needs receive_context.h.
#   libicd       — image codec library used by libahtse and mod_mrf.
#   libahtse     — core AHTSE library that all Apache modules link against.
build_repo_smart "mod_receive"
build_repo_smart "libicd"
build_repo_smart "libahtse"

# mod_mrf uses a custom Makefile.lcl because it needs explicit -I paths to the
# three libraries built above that a generic Makefile.lcl.example won't know about.
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
# install_mod_load NAME CONTENTS
# Writes a <name>.load file to mods-available with the given Apache directives,
# then symlinks it into mods-enabled (idempotent; skips if the symlink exists).
# NAME   — module name without the .load extension (e.g. "mrf").
# CONTENTS — multi-line string with LoadFile / LoadModule directives.
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