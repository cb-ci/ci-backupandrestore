#! /bin/bash

#docker login

docker build -t caternberg/aws-cli:1.3 .
docker push caternberg/aws-cli:1.3