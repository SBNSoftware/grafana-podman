#!/bin/bash

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    echo "This script is being sourced. Please run it instead."
    return 1
fi

for var in XDG_DATA_HOME XDG_CONFIG_HOME XDG_CACHE_HOME; do
    if [[ "${!var}" == *".dotfiles"* ]]; then
        echo "Error: This script should be run in a clean bash environment without .dotfiles in XDG paths."
        echo "Please run 'env -i bash -l' to start a clean bash session before executing this script."
        exit 1
    fi
done

echo "The bash environment passed the test."
exit 0
