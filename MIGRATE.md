# Migrating or Replicating this Lab to a New Raspberry Pi

Config files alone aren't enough — provisioned subscribers, the WebUI admin
account, and SIP registration state only exist in the running MongoDB volume
/ container state. This covers both scenarios:

- **Migration** — the old Pi is going away. Fastest path, uses a raw volume
  tar, requires a brief `docker compose down` on the source.
- **Replication** — the old Pi keeps running untouched. Uses `mongodump`
  (safe against a live database), no downtime on the source at all.

Both end with the same critical last step, added after a real replication
run surfaced a startup race: **restart the sipclients along with the RAN
containers**, not just gnb/ue/ue2 — otherwise a sipclient can start before
its paired UE's ims tunnel exists, silently bind to the wrong interface, and
register once before failing on every refresh ("Network is unreachable").

## Option A — Migration (old Pi stops)

### On the OLD Pi (source)

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
  README.md ims.md MIGRATE.md mongo-data.tar.gz

ls -lh ~/open5gs-lab-migration.tar.gz
```

Copy that single file to the new Pi:

```bash
scp ~/open5gs-lab-migration.tar.gz aaron@<new-pi-ip>:~/
```

### On the NEW Pi (destination)

```bash
# 1. Docker (skip if already installed)
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER   # log out/in (or `newgrp docker`) before using docker

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

# 5. Restart in order: RAN, then IMS clients (this is the step that was missing)
docker compose restart gnb
sleep 5 && docker compose logs gnb   # want: NG Setup procedure is successful
docker compose restart ue ue2
sleep 8 && docker compose logs ue    # want: PDU Session establishment x2 (internet + ims)
docker compose restart sipclient1 sipclient2
sleep 3

# 6. Verify data plane + SIP registration carried over
docker compose exec ue ping -c 3 -I uesimtun0 8.8.8.8   # check actual tun name first
docker compose logs sipclient1 | tail -5
docker compose logs sipclient2 | tail -5
# want on both: "Detected ims interface: uesimtun<N>" (never blank) and a
# clean "200 OK ... All 1 useragent registered successfully!" with no
# subsequent "Network is unreachable" lines
```

## Option B — Replication (old Pi stays running)

### On the existing Pi (no downtime, no `docker compose down`)

```bash
cd ~/open5gs-docker-lab

# 1. Consistent DB snapshot WITHOUT stopping mongo — mongodump is safe
#    against a live database, unlike raw-copying the WiredTiger files.
docker compose exec -T mongo mongodump --db open5gs --archive --gzip > open5gs-mongo.dump.gz

# 2. Package configs + the dump — no downtime anywhere in this step.
tar czf ~/open5gs-lab-replica.tar.gz \
  docker-compose.yml core ueransim ims baresip \
  README.md ims.md MIGRATE.md open5gs-mongo.dump.gz

ls -lh ~/open5gs-lab-replica.tar.gz
```

```bash
scp ~/open5gs-lab-replica.tar.gz aaron@<new-pi-ip>:~/
```

### On the new Pi (nothing installed yet)

```bash
# 1. Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER   # log out/in (or `newgrp docker`) before using docker

# 2. Unpack
mkdir -p ~/open5gs-docker-lab && cd ~/open5gs-docker-lab
tar xzf ~/open5gs-lab-replica.tar.gz

# 3. Bring up only mongo first, empty, then restore into it
docker compose up -d mongo
sleep 10
docker compose exec -T mongo mongorestore --db open5gs --archive --gzip < open5gs-mongo.dump.gz

# 4. Bring up the rest of the stack
docker compose up -d
sleep 20
docker compose logs core | grep -c ERROR   # want 0

# 5. Restart in order: RAN, then IMS clients (this is the step that was missing)
docker compose restart gnb
sleep 5 && docker compose logs gnb   # want: NG Setup procedure is successful
docker compose restart ue ue2
sleep 8 && docker compose logs ue    # want: PDU Session establishment x2
docker compose restart sipclient1 sipclient2
sleep 3

# 6. Verify data plane + SIP registration carried over
docker compose exec ue ping -c 3 -I uesimtun0 8.8.8.8
docker compose logs sipclient1 | tail -5
docker compose logs sipclient2 | tail -5
# want on both: "Detected ims interface: uesimtun<N>" (never blank) and a
# clean successful registration with no "Network is unreachable" lines
```

If both sipclients show a clean registration with no unreachable errors, the
new Pi has its own independent, fully working copy — same subscribers, same
WebUI login, same SIP accounts — while the original (Option B) keeps running
exactly as it was, completely untouched.

## Why the sipclient restart matters

`docker compose up -d` starts every service together. `sipclient1`/`sipclient2`
detect their paired UE's ims tunnel interface (e.g. `uesimtun0`) at their own
boot time — if that detection runs before `ue`/`ue2` have actually finished
establishing the ims PDU session, it silently comes up blank and baresip
falls back to binding on `eth0` (the Docker bridge IP) instead. The initial
REGISTER can still succeed from there (Kamailio is reachable on the bridge
too), which masks the problem — but the periodic re-registration then fails
with "Network is unreachable" because it's bound to the wrong interface.
Restarting the sipclients *after* ue/ue2 are confirmed up removes the race
entirely, since the tunnel already exists by the time detection runs again.

## Notes

- Same architecture required: this only works Pi-to-Pi (arm64 to arm64). The
  Mongo volume/dump and image layers are arch-specific.
- If you're also changing IPs/subnet: everything in `core/*.yaml`,
  `ueransim/*.yaml`, and `docker-compose.yml` hardcodes `10.33.33.0/24` — the
  Docker bridge network is self-contained per-host, so running the same
  scheme on two different physical Pis simultaneously (Option B) is fine
  with zero conflict, since bridges aren't visible across hosts.
- Detaching from an attached container: always Ctrl-P then Ctrl-Q. Ctrl-C
  sends SIGINT and kills/restarts the container instead.
- Bigger subscriber base or long-term production-like migration: `mongodump`/
  `mongorestore` (Option B) is the safer, cross-version-friendly choice in
  general — Option A's raw volume tar only stays safe because both Pis run
  identical `mongo:4.4.18`.
