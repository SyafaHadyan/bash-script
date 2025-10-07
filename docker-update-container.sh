#!/bin/bash

docker stop $1
docker rm $1
cat $1 | bash
