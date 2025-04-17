#!/bin/bash

for ((i = 1; i <= $2; i++)); do
    $1 >"$3/result_$i.txt"
done

all_match=true
for ((i = 1; i <= $2; i++)); do
    for ((j = i + 1; j <= $2; j++)); do
        if ! diff -q "$3/result_$i.txt" "$3/result_$j.txt"; then
            echo "Difference found between result_$i.txt and result_$j.txt" >>"$3/run-result.txt"
            all_match=false
        fi
    done
done

if $all_match; then
    echo "All output files are identical." >>"$3/run-result.txt"
fi
