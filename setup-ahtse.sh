#!/usr/bin/env bash
set -euo pipefail

echo "=== AHTSE Server Setup (Noble-friendly) ==="
export DEBIAN_FRONTEND=noninteractive

# -----------------------------
# 0) Packages
# -----------------------------
echo "[1/8] Installing dependencies..."
sudo apt-get update -y
sudo apt-get install -y \
  apache2 apache2-dev \
  gdal-bin libgdal-dev \
  build-essential cmake pkg-config \
  libapr1-dev libaprutil1-dev \
  libjpeg-dev libpng-dev zlib1g-dev \
  libcurl4-openssl-dev \
  sqlite3 libsqlite3-dev \
  git libpcre2-dev

# Set a global ServerName to avoid AH00558 warning
echo "[1a/8] Setting global ServerName to localhost..."
echo "ServerName localhost" | sudo tee /etc/apache2/conf-available/servername.conf >/dev/null
sudo a2enconf servername >/dev/null
sudo apachectl restart || true

# -----------------------------
# 1) Discover build paths
# -----------------------------
echo "[2/8] Discovering Apache/APR include paths..."
APXS_BIN=${APXS_BIN:-apxs}
APR_INC="$(apr-1-config --includedir 2>/dev/null || echo /usr/include/apr-1)"
AP_INC="$($APXS_BIN -q includedir 2>/dev/null || echo /usr/include/apache2)"
AP_LIBEXECDIR="$($APXS_BIN -q libexecdir 2>/dev/null || echo /usr/lib/apache2/modules)"
echo "  APR_INC=${APR_INC}"
echo "  AP_INC=${AP_INC}"
echo "  AP_LIBEXECDIR=${AP_LIBEXECDIR}"

# Safety net for compilers that ignore Makefile EXTRA_INCLUDES
export CPATH="${APR_INC}:${AP_INC}:${CPATH:-}"
export CPLUS_INCLUDE_PATH="${APR_INC}:${AP_INC}:${CPLUS_INCLUDE_PATH:-}"

# -----------------------------
# 2) Create dirs & ld.so config
# -----------------------------
echo "[3/8] Creating build/install directories..."
for dir in "$HOME/wms_modules" "$HOME/modules" "$HOME/lib" "$HOME/include"; do
  mkdir -p "$dir"
done

echo "[4/8] Registering \$HOME/lib for dynamic linker..."
echo "$HOME/lib" | sudo tee /etc/ld.so.conf.d/ahtse.conf >/dev/null
sudo ldconfig

# -----------------------------
# 3) Clone repos
# -----------------------------
echo "[5/8] Cloning repositories..."
cd "$HOME/wms_modules"
for repo in libahtse AHTSE libicd mod_mrf mod_receive mod_sfim mod_reproject mod_convert; do
  if [ -d "$repo/.git" ]; then
    echo "  - $repo already cloned"
  else
    git clone --depth=1 "https://github.com/lucianpls/$repo.git"
  fi
done

# Optional: sanitize upstream hardcoded APR include paths
echo "[5a/8] Normalizing any hardcoded APR include paths in Makefiles (if present)..."
find "$HOME/wms_modules" -type f -name 'Makefile*' -print0 \
  | xargs -0 sed -i 's#/usr/include/apr-1\.0#$(APR_INC)#g' || true

# -----------------------------
# Helpers
# -----------------------------
make_lcl_common() {
  # Writes a Makefile.lcl in CWD that pulls include dirs dynamically.
  # Extra user-provided -I paths can be appended by setting EXTRA_DEPS_INC.
  cat > Makefile.lcl <<EOF
PREFIX ?= \$(HOME)
APXS ?= apxs

APR_INC    = \$(shell apr-1-config --includedir 2>/dev/null || echo /usr/include/apr-1)
AP_INC     = \$(shell \$(APXS) -q includedir 2>/dev/null)
EXP_INCLUDEDIR = \$(PREFIX)/include
LIBEXECDIR    = \$(shell \$(APXS) -q libexecdir 2>/dev/null)

EXTRA_INCLUDES = -I\$(AP_INC) -I\$(APR_INC) -I\$(HOME)/include ${EXTRA_DEPS_INC:-}
EOF
}

enable_mod() {
  local name="$1"
  if [ -f "/etc/apache2/mods-available/${name}.load" ]; then
    sudo ln -sf "/etc/apache2/mods-available/${name}.load" "/etc/apache2/mods-enabled/${name}.load"
  fi
}

# -----------------------------
# 4) Build (ORDER MATTERS)
#    mod_receive -> libicd -> libahtse -> others
# -----------------------------

echo "[6/8] Building mod_receive (headers needed by libahtse)..."
cd "$HOME/wms_modules/mod_receive/src"
EXTRA_DEPS_INC=""
if [ -f Makefile.lcl.example ]; then
  cp -f Makefile.lcl.example Makefile.lcl
else
  make_lcl_common
fi
make -j"$(nproc)"
make install

# Expose receive headers to dependents (libahtse expects receive_context.h)
if [ -f "$HOME/wms_modules/mod_receive/src/receive_context.h" ]; then
  install -Dm644 "$HOME/wms_modules/mod_receive/src/receive_context.h" "$HOME/include/receive_context.h"
fi

echo "[6a/8] Building libicd..."
cd "$HOME/wms_modules/libicd/src"
EXTRA_DEPS_INC=""
if [ -f Makefile.lcl.example ]; then
  cp -f Makefile.lcl.example Makefile.lcl
else
  make_lcl_common
fi
if make -n >/dev/null 2>&1; then
  make -j"$(nproc)"
  make install
else
  # Try CMake layout if Makefile not present
  cd "$HOME/wms_modules/libicd"
  if [ -f CMakeLists.txt ]; then
    cmake -S . -B build -DCMAKE_INSTALL_PREFIX="$HOME" -DCMAKE_BUILD_TYPE=Release
    cmake --build build -j"$(nproc)"
    cmake --install build
  else
    echo "ERROR: libicd build files not found."
    exit 1
  fi
fi

# Flatten libicd headers into $HOME/include if they landed in a subdir
mkdir -p "$HOME/include"
if [ ! -f "$HOME/include/icd_codecs.h" ] && compgen -G "$HOME/include/**/icd_codecs.h" > /dev/null; then
  first_icd="$(compgen -G "$HOME/include/**/icd_codecs.h" | head -n1)"
  ln -sf "$(dirname "$first_icd")"/* "$HOME/include/" || true
fi

echo "[6b/8] Building libahtse (needs mod_receive + libicd headers)..."
cd "$HOME/wms_modules/libahtse/src"
# Add explicit deps includes for libahtse
EXTRA_DEPS_INC="-I../../libicd/src -I../../mod_receive/src"
if [ -f Makefile.lcl.example ]; then
  cp -f Makefile.lcl.example Makefile.lcl
  # ensure EXTRA_INCLUDES present by appending our includes to the end
  cat >> Makefile.lcl <<EOF

# Inject required include paths for dependencies
APR_INC    = \$(shell apr-1-config --includedir 2>/dev/null || echo /usr/include/apr-1)
AP_INC     = \$(shell \$(APXS) -q includedir 2>/dev/null)
EXTRA_INCLUDES += -I\$(AP_INC) -I\$(APR_INC) -I\$(HOME)/include ${EXTRA_DEPS_INC}
EOF
else
  make_lcl_common
fi

export CPLUS_INCLUDE_PATH="$HOME/include:${CPLUS_INCLUDE_PATH:-}"
make clean || true
make -j"$(nproc)"
make install

echo "[6c/8] Building mod_mrf..."
cd "$HOME/wms_modules/mod_mrf/src"
# For mod_mrf we always write a Makefile.lcl with explicit deps:
cat > Makefile.lcl <<EOF
APXS = apxs
PREFIX ?= \$(HOME)
APR_INC    = \$(shell apr-1-config --includedir 2>/dev/null || echo /usr/include/apr-1)
includedir = \$(shell \$(APXS) -q includedir 2>/dev/null)
EXTRA_INCLUDES = -I\$(includedir) -I\$(APR_INC) -I../../libahtse/src -I../../libicd/src -I../../mod_receive/src -I\$(HOME)/include
LIBTOOL = \$(shell \$(APXS) -q LIBTOOL 2>/dev/null)
LIBEXECDIR = \$(shell \$(APXS) -q libexecdir 2>/dev/null)
EXP_INCLUDEDIR = \$(PREFIX)/include
CP = cp
DEST = \$(PREFIX)/modules
EOF
make clean || true
make -j"$(nproc)"
make install

echo "[6d/8] Building mod_convert..."
cd "$HOME/wms_modules/mod_convert/src"
EXTRA_DEPS_INC="-I../../libahtse/src -I../../libicd/src -I../../mod_receive/src"
if [ -f Makefile.lcl.example ]; then
  cp -f Makefile.lcl.example Makefile.lcl
  cat >> Makefile.lcl <<EOF

APR_INC    = \$(shell apr-1-config --includedir 2>/dev/null || echo /usr/include/apr-1)
AP_INC     = \$(shell \$(APXS) -q includedir 2>/dev/null)
EXTRA_INCLUDES += -I\$(AP_INC) -I\$(APR_INC) -I\$(HOME)/include ${EXTRA_DEPS_INC}
EOF
else
  make_lcl_common
fi
make clean || true
make -j"$(nproc)"
make install

echo "[6e/8] Building mod_reproject/mod_retile..."
cd "$HOME/wms_modules/mod_reproject/src"
EXTRA_DEPS_INC="-I../../libahtse/src -I../../libicd/src -I../../mod_receive/src"
if [ -f Makefile.lcl.example ]; then
  cp -f Makefile.lcl.example Makefile.lcl
  cat >> Makefile.lcl <<EOF

APR_INC    = \$(shell apr-1-config --includedir 2>/dev/null || echo /usr/include/apr-1)
AP_INC     = \$(shell \$(APXS) -q includedir 2>/dev/null)
EXTRA_INCLUDES += -I\$(AP_INC) -I\$(APR_INC) -I\$(HOME)/include ${EXTRA_DEPS_INC}
EOF
else
  make_lcl_common
fi
make clean || true
make -j"$(nproc)"
make install

echo "[6f/8] Building mod_sfim..."
cd "$HOME/wms_modules/mod_sfim"

# Clean out any previous broken sfim.load to avoid blocking configtest
sudo rm -f /etc/apache2/mods-enabled/sfim.load /etc/apache2/mods-available/sfim.load || true

SFIM_SO_PATH=""
if [ -f src/Makefile ] || [ -f Makefile ]; then
  make -j"$(nproc)" || true
  sudo make install || true
  # If 'make install' put it in the Apache modules dir, remember that path
  if [ -f "$AP_LIBEXECDIR/mod_sfim.so" ]; then
    SFIM_SO_PATH="$AP_LIBEXECDIR/mod_sfim.so"
  fi
else
  # Typical build is via apxs; try both compile and install
  apxs -c mod_sfim.c || true
  mkdir -p "$HOME/modules"
  if [ -f ".libs/mod_sfim.so" ]; then
    cp -f .libs/mod_sfim.so "$HOME/modules/"
    SFIM_SO_PATH="$HOME/modules/mod_sfim.so"
  fi
  # Also install to Apache's module dir (optional)
  apxs -i -n sfim mod_sfim.la || true
  # If apxs installed it, record that path as fallback
  if [ -z "$SFIM_SO_PATH" ] && [ -f "$AP_LIBEXECDIR/mod_sfim.so" ]; then
    SFIM_SO_PATH="$AP_LIBEXECDIR/mod_sfim.so"
  fi
fi

# Final check: do we have a built .so anywhere?
if [ -z "$SFIM_SO_PATH" ]; then
  echo "WARN: mod_sfim.so was not produced; skipping Apache load for sfim."
else
  echo "mod_sfim.so found at: $SFIM_SO_PATH"
fi

sudo ldconfig

# -----------------------------
# 5) Apache module load files
# -----------------------------
echo "[7/8] Installing Apache module .load files..."
sudo mkdir -p /etc/apache2/mods-available /etc/apache2/mods-enabled

# mrf
if [ -f "$HOME/modules/mod_mrf.so" ]; then
  sudo tee /etc/apache2/mods-available/mrf.load >/dev/null <<EOF
LoadFile $HOME/modules/libahtse.so
LoadModule mrf_module $HOME/modules/mod_mrf.so
EOF
  enable_mod mrf
fi

# convert
if [ -f "$HOME/modules/mod_convert.so" ]; then
  sudo tee /etc/apache2/mods-available/convert.load >/dev/null <<EOF
LoadFile $HOME/modules/libahtse.so
LoadModule convert_module $HOME/modules/mod_convert.so
EOF
  enable_mod convert
fi

# receive (guarded)
if [ -f "$HOME/modules/mod_receive.so" ]; then
  sudo tee /etc/apache2/mods-available/receive.load >/dev/null <<EOF
LoadModule receive_module $HOME/modules/mod_receive.so
EOF
  enable_mod receive
fi

# retile (guarded)
if [ -f "$HOME/modules/mod_retile.so" ]; then
  sudo tee /etc/apache2/mods-available/retile.load >/dev/null <<EOF
LoadModule retile_module $HOME/modules/mod_retile.so
EOF
  enable_mod retile
fi

# sfim (guarded & auto-detected path)
if [ -z "${SFIM_SO_PATH:-}" ]; then
  if [ -f "$HOME/modules/mod_sfim.so" ]; then
    SFIM_SO_PATH="$HOME/modules/mod_sfim.so"
  elif [ -f "$AP_LIBEXECDIR/mod_sfim.so" ]; then
    SFIM_SO_PATH="$AP_LIBEXECDIR/mod_sfim.so"
  fi
fi
if [ -n "${SFIM_SO_PATH:-}" ] && [ -f "$SFIM_SO_PATH" ]; then
  sudo tee /etc/apache2/mods-available/sfim.load >/dev/null <<EOF
LoadModule sfim_module $SFIM_SO_PATH
EOF
  enable_mod sfim
else
  echo "INFO: sfim module not built; not creating sfim.load."
fi

echo "[7a/8] Checking Apache config..."
echo "Built modules present under \$HOME/modules (if any):"
ls -l "$HOME/modules" || true

sudo apachectl configtest || (echo "Apache config test failed" && exit 1)
sudo apachectl restart

# -----------------------------
# 6) Site setup
# -----------------------------
echo "[8/8] Creating OpenSpace site..."
sudo mkdir -p /var/www/openspace
sudo chown -R www-data:www-data /var/www/openspace

sudo tee /etc/apache2/sites-available/100-ahtse.conf >/dev/null <<'EOF'
# Expose your data root at /tiles/
Alias /tiles/ "/workspaces/OpenSpace-x-ClimateReanalyzer-Server/data/"

<Directory "/workspaces/OpenSpace-x-ClimateReanalyzer-Server/data/">
    Options -Indexes -FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>

# Pull in the blocks your genconf created (MRF_RegExp + MRF_ConfigurationFile)
Include "/workspaces/OpenSpace-x-ClimateReanalyzer-Server/ahtse.conf"
EOF

sudo ln -sf /etc/apache2/sites-available/100-ahtse.conf /etc/apache2/sites-enabled/100-ahtse.conf

sudo apachectl configtest && sudo service apache2 restart
echo "=== AHTSE server install complete! ==="

echo
echo "Quick checks:"
echo "  apachectl -M | grep -E 'mrf|convert|receive|retile|sfim'  # should list loaded modules (sfim only if built)"
echo "  curl -I http://localhost/                              # 200 OK"
