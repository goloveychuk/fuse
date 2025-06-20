#!/bin/bash

# Default path if not provided
DIR_PATH=${1}
echo "DIR_PATH: $DIR_PATH"
echo 3 | sudo tee /proc/sys/vm/drop_caches

time find "$DIR_PATH" -type f -name "*.js" -exec cat {} \; > /dev/null
echo try2
time find "$DIR_PATH" -type f -name "*.js" -exec cat {} \; > /dev/null


