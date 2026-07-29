# Migrating or Replicating this Lab to a New Raspberry Pi

Config files alone aren't enough — provisioned subscribers, the WebUI admin
account, and SIP registration state only exist in the running MongoDB volume
/ container state. This covers both scenarios:

- **Migration** — the old Pi is going away. Fastest path, uses a raw volume
  tar, requires a brief `docker compose down` on the source.
- **Replication** — the old Pi keeps running untouched. Uses `mongodump`
  (safe against a live database), no downtime on the source at all.

Both scenarios hit the same set of startup-sequencing bugs on the new Pi,
found the hard way across several real replication runs. Section
["Known Issues / Bring-Up Playbook"](#known-issues--bring-up-playbook) below
covers all of them and is the reason `up.sh` exists — **use `up.sh` instead
of raw `docker compose up -d` any time `core`/`gnb`/`ue`/`ue2` are touched.**

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

# 3. Package everything (configs + IMS + db snapshot + the bring-up script)
tar czf ~/open5gs-lab-migration.tar.gz \
  docker-compose.yml core ueransim ims baresip \
  README.md ims.md MIGRATE.md up.sh mongo-data.tar.gz

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
chmod +x up.sh

# 3. Create the named volume and restore data into it BEFORE first `up`
docker volume create open5gs-docker-lab_mongo-data
docker run --rm \
  -v open5gs-docker-lab_mongo-data:/data \
  -v "$PWD":/backup \
  busybox tar xzf /backup/mongo-data.tar.gz -C /data

# 4. Bring the whole stack up correctly in one shot
./up.sh

# 5. Verify — don't trust registration success alone, see Known Issues below
docker compose exec ue ping -c 3 -I uesimtun0 8.8.8.8   # check actual tun name first
docker compose logs sipclient1 --tail 10
docker compose logs sipclient2 --tail 10
```

## Option B — Replication (old Pi stays running)

### On the existing Pi (no downtime, no `docker compose down`)

```bash
cd ~/open5gs-docker-lab

# 1. Consistent DB snapshot WITHOUT stopping mongo — mongodump is safe
#    against a live database, unlike raw-copying the WiredTiger files.
docker compose exec -T mongo mongodump --db open5gs --archive --gzip > open5gs-mongo.dump.gz

# 2. Package configs + the dump + the bring-up script — no downtime here.
tar czf ~/open5gs-lab-replica.tar.gz \
  docker-compose.yml core ueransim ims baresip \
  README.md ims.md MIGRATE.md up.sh open5gs-mongo.dump.gz

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
chmod +x up.sh

# 3. Bring up only mongo first, empty, then restore into it
docker compose up -d mongo
sleep 10
docker compose exec -T mongo mongorestore --db open5gs --archive --gzip < open5gs-mongo.dump.gz

# 4. Bring up the rest of the stack correctly in one shot
./up.sh

# 5. Verify — don't trust registration success alone, see Known Issues below
docker compose exec ue ping -c 3 -I uesimtun0 8.8.8.8
docker compose logs sipclient1 --tail 10
docker compose logs sipclient2 --tail 10
```

If both sipclients show `Detected ims interface: uesimtun<N>` (never blank)
and the ping succeeds, the new Pi has its own independent, fully working
copy — same subscribers, same WebUI login, same SIP accounts — while the
original (Option B) keeps running exactly as it was, completely untouched.

## up.sh — the standard bring-up sequence

```bash
cat > ~/open5gs-docker-lab/up.sh <<'EOF'
#!/bin/bash
set -e
cd ~/open5gs-docker-lab

docker compose up -d mongo core webui
docker compose up -d gnb          # fixed-delay start, see Known Issues #1
sleep 20
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
EOF
chmod +x ~/open5gs-docker-lab/up.sh
```

`gnb`'s own entry in `docker-compose.yml` needs to match Known Issue #1's
fixed-delay command (`sleep 15; exec nr-gnb -c /config/gnb.yaml`) for this
script to be reliable — see below if it still shows the old `until ...`
TCP-probe version.

## Known Issues / Bring-Up Playbook

Four distinct bugs were found across real replication runs, all in how the
stack starts up rather than in the core config itself. In the order you're
likely to hit them:

### 1. gNB never retries its SCTP connection to AMF

**Symptom:** `gnb` logs one `SCTP could not connect: Connection refused` at
boot and then nothing — `ue`/`ue2` sit in an endless "Cell selection
failure" / "PLMN selection failure" loop, because UERANSIM's `nr-gnb` does
not auto-reconnect after a failed SCTP attempt.

**Root cause:** `gnb` started before `core`'s AMF had finished initializing.

**Fix — make the start self-healing.** A first attempt at this used a
`until (echo > /dev/tcp/host/38412)...` bash readiness loop before launching
`nr-gnb` — **this does not work**, because bash's `/dev/tcp` only speaks TCP,
and AMF's NGAP port is SCTP-only; the probe fails forever regardless of
whether AMF is actually ready. The reliable fix for a lab environment is a
plain fixed delay instead of a broken protocol-mismatched check:

```yaml
  gnb:
    image: gradiant/ueransim:3.2.6   # multi-arch; fallback: build ./ueransim/Dockerfile
    entrypoint: ["/bin/bash", "-c"]
    command: ["sleep 15; exec nr-gnb -c /config/gnb.yaml"]
    volumes:
      - ./ueransim:/config
    depends_on: [core]
    networks:
      n5g:
        ipv4_address: 10.33.33.5
```

If `gnb` still shows the old `until` version, edit only that line (see the
block-aware Python patch pattern in the project history — never blind
find/replace, since `ue`/`ue2` share similarly-shaped lines).

If it happens anyway despite the delay (e.g. a slower first boot): manually
recover with `docker compose restart gnb`, then `restart ue ue2` once gnb's
log shows `NG Setup procedure is successful`.

### 2. sipclient binds to the wrong interface if it starts before its UE's tunnel exists

**Symptom:** `sipclient1`/`sipclient2` register successfully once, then every
periodic re-registration fails with `Register: Network is unreachable`.

**Root cause:** `sipclient1`/`sipclient2` detect their paired UE's `ims`
tunnel interface (e.g. `uesimtun0`) at their own boot time. If that
detection runs before `ue`/`ue2` have finished establishing the `ims` PDU
session, it silently comes up blank and baresip falls back to binding on
`eth0` (the Docker bridge IP) instead. The initial REGISTER can still
succeed from there — Kamailio is reachable on the bridge too — which masks
the problem until the next refresh fails.

**This is also the reason a "200 OK ... registered successfully" log line is
not sufficient proof the IMS-over-5GC path is actually working** — it can
be a false positive via the bridge. Always confirm with both of these:

```bash
docker compose logs sipclient1 --tail 20 | grep -iE "detected|local network"
# want: Detected ims interface: uesimtun<N>  (NOT blank, NOT "eth0")

docker compose exec ue ping -c 3 -I uesimtun<N> 10.33.33.7
# want: 0% packet loss — real proof traffic rides the actual PDU session
```

**Fix:** restart the sipclients *after* `ue`/`ue2` are confirmed up —
`up.sh` already does this. If `ue`/`ue2` were only restarted (not
recreated), `docker compose restart sipclient1 sipclient2` is enough. If
`ue`/`ue2` were recreated (see Issue #3), a plain restart isn't enough —
use `--force-recreate`.

### 3. sipclient can't rejoin its UE's network namespace after ue/ue2 is recreated

**Symptom:** `docker compose restart sipclient1` fails outright with
`joining network namespace of container: No such container: <id>`.

**Root cause:** `network_mode: service:ue` binds to the *specific container
instance* that existed when the sipclient was created — not dynamically to
"whatever `ue` currently is." If `ue` is later **recreated** (not just
restarted — e.g. its image changed, such as after rebuilding it with the
traceroute/speedtest-cli tooling), the old container it was bound to no
longer exists.

**Fix:** recreate the sipclients too, don't just restart them:

```bash
docker compose up -d --force-recreate sipclient1 sipclient2
```

Rule of thumb: `ue`/`ue2` **restarted** (same container, same image) →
plain `restart` on the sipclients is fine. `ue`/`ue2` **recreated** (new
container — image/config change) → sipclients need `--force-recreate`.

### 4. Stale UPF session state after several ue/ue2 recreate cycles without restarting core

**Symptom:** Everything looks correctly configured — the static route on
`ims` back to `10.46.0.0/16` is present, the NAT rule on `core`
(`MASQUERADE ... 10.46.0.0/16 -> 0.0.0.0/0`) is present, Kamailio is
listening — yet REGISTER consistently fails with `Connection timed out`,
and a live `tcpdump` on `ims`'s own interface shows **zero packets ever
arriving**, confirming the SIP traffic never leaves the 5GC at all.

**Root cause:** `ue`/`ue2` had been recreated/restarted many times across a
long troubleshooting session while `core` itself was never restarted. The
UPF's internal GTP session/tunnel bookkeeping for the `ims` DNN drifted out
of sync with the actual current sessions.

**Fix:** restart `core` itself to force the UPF to rebuild its session
table cleanly, then walk the RAN chain back up in order:

```bash
docker compose restart core
sleep 15 && docker compose logs core | grep -c ERROR   # want 0
docker compose up -d gnb        # or restart, if using the fixed-delay version
sleep 20 && docker compose logs gnb --tail 10           # want: NG Setup procedure is successful
docker compose restart ue ue2
sleep 8 && docker compose logs ue --tail 10             # want: PDU Session establishment x2
docker compose restart sipclient1 sipclient2
sleep 3
```

**Rule of thumb:** if `ue`/`ue2` have gone through several recreate/restart
cycles during a session without `core` itself ever restarting, and IMS
registration is timing out despite everything *looking* correctly
configured, restart `core` before troubleshooting anything else on the IMS
side.

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
