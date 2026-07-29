#!/bin/bash
set -e
cd ~/open5gs-docker-lab

docker compose up -d mongo core webui
docker compose up -d gnb          # self-healing now, waits for AMF internally
sleep 8
docker compose up -d ue ue2
sleep 8
docker compose logs ue --tail 5

docker compose up -d ims
sleep 2

# always force-recreate, cheap and guarantees no stale netns binding
docker compose up -d --force-recreate sipclient1 sipclient2
sleep 3
docker compose logs sipclient1 --tail 5
docker compose logs sipclient2 --tail 5
