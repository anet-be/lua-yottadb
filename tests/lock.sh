#!/bin/bash
# Helper script for locking keys.
pwd="`pwd`"
dir="`dirname $pwd`"
#lua -e "package.path='$dir/?.lua'" $@ &
lua tests/lock.lua $@ &
