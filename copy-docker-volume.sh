#!/bin/bash

docker run --rm --volumes-from $1 -v $(pwd):/backup ubuntu tar cvf /backup/backup.tar $2
