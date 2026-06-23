#!/bin/bash
set -e

# --- CONFIGURATION ---
# Update these paths before running
export ANDROID_NDK_HOME="/path/to/your/android-ndk"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
export TARGET_OS=$1 # "android" or "ios"

PREFIX="$(pwd)/prebuilt/$TARGET_OS"
mkdir -p "$PREFIX" src

# --- DEPENDENCY VERSIONS ---
GMP_VER="6.3.0"
NETTLE_VER="3.9.1"

cd src

# 1. BUILD GMP
if [ ! -d "gmp-$GMP_VER" ]; then
    curl -LO "https://gmplib.org/download/gmp/gmp-$GMP_VER.tar.xz"
    tar -xf "gmp-$GMP_VER.tar.xz"
fi
cd "gmp-$GMP_VER"
make clean || true

if [ "$TARGET_OS" = "android" ]; then
    # Android arm64-v8a toolchain setup
    TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin"
    export CC="$TOOLCHAIN/aarch64-linux-android30-clang"
    export CXX="$TOOLCHAIN/aarch64-linux-android30-clang++"
    
    ./configure --host=aarch64-linux-android --prefix="$PREFIX" \
        --disable-assembly --enable-static --disable-shared
elif [ "$TARGET_OS" = "ios" ]; then
    # iOS arm64 setup
    export SDKROOT="$DEVELOPER_DIR/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"
    export CC="clang -arch arm64 -isysroot $SDKROOT -miphoneos-version-min=13.0"
    
    ./configure --host=aarch64-apple-darwin --prefix="$PREFIX" \
        --disable-assembly --enable-static --disable-shared
else
    echo "Usage: ./build_dependencies.sh [android|ios]" && exit 1
fi

make -j$(sysctl -n hw.ncpu || nproc)
make install
cd ..

# 2. BUILD NETTLE
if [ ! -d "nettle-$NETTLE_VER" ]; then
    curl -LO "https://ftp.gnu.org/gnu/nettle/nettle-$NETTLE_VER.tar.gz"
    tar -xf "nettle-$NETTLE_VER.tar.gz"
fi
cd "nettle-$NETTLE_VER"
make clean || true

# Nettle needs to know where GMP headers/libs are located
export CFLAGS="-I$PREFIX/include"
export LDFLAGS="-L$PREFIX/lib"

if [ "$TARGET_OS" = "android" ]; then
    ./configure --host=aarch64-linux-android --prefix="$PREFIX" \
        --disable-assembly --enable-static --disable-shared --disable-openssl
elif [ "$TARGET_OS" = "ios" ]; then
    ./configure --host=aarch64-apple-darwin --prefix="$PREFIX" \
        --disable-assembly --enable-static --disable-shared --disable-openssl
fi

make -j$(sysctl -n hw.ncpu || nproc)
make install
cd ..