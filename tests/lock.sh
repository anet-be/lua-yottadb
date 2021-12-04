#!/bin/bash
# Helper script for locking keys.
pwd="`pwd`"
dir="`dirname $pwd`"
#lua5.3 -e "package.path='$dir/?.lua'" $@ &
lua5.3 tests/lock.lua $@ &
