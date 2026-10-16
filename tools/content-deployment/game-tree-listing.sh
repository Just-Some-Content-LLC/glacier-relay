#!/bin/bash
# Read-only listing of the installation's Runtime and Retail trees: size, mtime, path (sorted by path).
#   game-tree-listing.sh <game-root>
GD=${1:?game root}
cd "$GD" && find Runtime Retail -type f -printf '%s\t%TY-%Tm-%TdT%TH:%TM:%TS\t%p\n' | sort -k3
