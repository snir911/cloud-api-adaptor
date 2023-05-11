#!/bin/bash

FOLDERS="/etc /usr/local/bin /pause_bundle"

for entry in $FOLDERS
do
    [[ -e $entry ]] && sudo restorecon -p -r $entry
done
