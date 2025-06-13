#!/bin/bash

set -e
curl -L https://github.com/libfuse/libfuse/releases/download/fuse-3.17.2/fuse-3.17.2.tar.gz | tar -xz
cd fuse-3.17.2
mkdir build
cd build
meson setup .. --prefix=/usr  --default-library=static --buildtype=release 

# Build the library
ninja

sudo ninja install
