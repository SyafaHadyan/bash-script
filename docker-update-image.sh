#!/bin/bash

while read -r image; do
    docker pull "$image"
done
