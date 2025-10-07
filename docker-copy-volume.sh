#!/bin/bash

docker container run --rm -it -v $1:/from -v $2:/to alpine sh -c "cd /from ; cp -av . /to"
