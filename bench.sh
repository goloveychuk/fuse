#!/bin/bash

# Default path if not provided
DIR_PATH=${1}
echo "DIR_PATH: $DIR_PATH"
echo 3 | sudo tee /proc/sys/vm/drop_caches
echo run1
time find "$DIR_PATH" -name "*.js" > /dev/null
echo run2
time find "$DIR_PATH" -name "*.js" > /dev/null
echo run3
time find "$DIR_PATH" -name "*.js" > /dev/null
echo run4
time find "$DIR_PATH" -name "*.js" > /dev/null