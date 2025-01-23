#!/bin/bash

# In order to run this script you need the scc tool installed
# https://github.com/boyter/scc
# brew install scc

scc . -p --include-symlinks --no-gitmodule --no-complexity --no-cocomo
