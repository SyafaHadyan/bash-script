#!/bin/bash

if [[ ! -e $e ]]; then
    mkdir $3
fi
for ((i = 0; i < $2; i++)); do
    if [[ $3 -eq 0 ]]; then
        $1 >"result_$i.txt"
    else
        $1 >"$3/result_$i.txt"
    fi
done
