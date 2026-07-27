# Migrating this lab to a new Raspberry Pi

Config files alone aren't enough — provisioned subscribers, the WebUI admin
account, and SIP registrations only exist in the running MongoDB volume /
container state. This migrates everything: 5GC + IMS.

## On the OLD Pi (source)

```bash
cd ~/open5gs-docker-lab

# 1. Stop everything cleanly (data stays in the named volume)
docker compose down

# 2. Snapshot the Mongo volume to a tarball
docker run --rm \
  -v open5gs-docker-lab_mongo-data:/data \
  -v "$PWD":/backup \
  busybox tar czf /backup/mongo-data.tar.gz -C /data .

# 3. Package everything (configs + IMS + db snapshot) into one archive
tar czf ~/open5gs-lab-migration.tar.gz \
  docker-compose.yml core ueransim ims baresip \
  README.md IMS.md MIGRATE.md mongo-data.tar.gz

ls -lh ~/open5gs-lab-migration.tar.gz
```

Copy that single file to the new Pi:
```bash
scp ~/open5gs-lab-migration.tar.gz aaron@<new-pi-ip>:~/
```

## On the NEW Pi (destination)

```bash
# 1. Docker (skip if already installed)
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER   # log out/in after this

# 2. Unpack
mkdir -p ~/open5gs-docker-lab && cd ~/open5gs-docker-lab
tar xzf ~/open5gs-lab-migration.tar.gz

# 3. Create the named volume and restore data into it BEFORE first `up`
docker volume create open5gs-docker-lab_mongo-data
docker run --rm \
  -v open5gs-docker-lab_mongo-data:/data \
  -v "$PWD":/backup \
  busybox tar xzf /backup/mongo-data.tar.gz -C /data

# 4. Bring the whole stack up (5GC + IMS + both virtual UEs + sipclients)
docker compose up -d
sleep 20
docker compose logs core | grep -c ERROR   # want 0 across every NF

# 5. Restart the RAN side in order — gNB never auto-associates on first boot
docker compose restart gnb
sleep 5 && docker compose logs gnb   # want: NG Setup procedure is successful
docker compose restart ue ue2
sleep 8 && docker compose logs ue    # want: PDU Session establishment x2 (internet + ims)

# 6. Confirm data plane + SIP registration carried over
docker compose exec ue ping -c 3 -I uesimtun0 8.8.8.8   # check actual tun name first
docker attach open5gs-docker-lab-sipclient1-1
# type: /reginfo   -> want OK, Expires 300s, with NO manual /uanew needed
```

If `/reginfo` shows registered without any manual steps, the migration
carried over your subscribers (999700000000001, 999700000000002), the WebUI
admin login, and the SIP accounts exactly as they were on the old Pi.

## Notes

- Same architecture required: arm64 to arm64 only (Mongo volume + image
  layers are arch-specific).
- Everything hardcodes `10.33.33.0/24` (docker bridge) and `10.45/10.46.0.0/16`
  (UE subnets) — self-contained per Docker host, so this is fine unmodified
  unless the new Pi already has a conflicting `10.33.33.0/24` network
  (`docker network ls` if unsure).
- Bigger subscriber base or production-like migration: prefer `mongodump`/
  `mongorestore` over raw volume tar for cross-version safety. Raw volume tar
  is used here because both Pis run identical `mongo:4.4.18`.
