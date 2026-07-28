# IMS Integration — Open5GS + UERANSIM + Kamailio SIP Call Demo

Adds a virtual IMS (voice-over-5G-style SIP call) on top of the working
Open5GS + UERANSIM 5G SA lab. Two simulated UEs each get a second PDU session
on a dedicated `ims` DNN, discover a P-CSCF via PCO, register against a
minimal Kamailio SIP proxy/registrar, and place a real SIP call with actual
RTP audio (opus, synthetic tone) between them.

**Known limitation:** this is signaling + media only, not full 3GPP VoNR.
Kamailio's IMS modules don't implement the N5/Rx interface to Open5GS's PCF,
so there's no dynamic QoS/AF-session interworking. For proving SIP
registration and calls between virtual UEs, none of that is needed.

## Architecture

```
[ue: 1001]  --ims PDU session (10.46.0.2)--\
     |                                       \
  (gnb, AMF/SMF/UPF as in base lab)           +--> [ims: Kamailio 10.33.33.7]
     |                                       /        SIP proxy/registrar
[ue2: 1002] --ims PDU session (10.46.0.3)--/
     |
[sipclient1] --- network_mode: service:ue  --- baresip, SIP user 1001
[sipclient2] --- network_mode: service:ue2 --- baresip, SIP user 1002
```

- `ue`/`ue2` each request **two** PDU sessions: `internet` (unchanged) and
  `ims` (new). The `ims` session's P-CSCF address is discovered from the
  SMF via PCO, pointing at Kamailio.
- `ogstun2` is the second TUN device on `core` carrying the `ims` subnet
  (`10.46.0.0/16`), NAT'd the same way as `internet`'s `ogstun`.
- `sipclient1`/`sipclient2` are `baresip` sidecars that share network
  namespace with `ue`/`ue2` (`network_mode: service:ue`) — same trick used
  for the tcpdump captures in the base lab. No changes to the UERANSIM image.
- RTP between the two UEs stays entirely inside `core`'s own `ogstun2`
  routing and never touches the docker bridge; only SIP signaling
  (REGISTER/INVITE to `10.33.33.7`) crosses from the `ims` subnet onto the
  bridge network.

## Directory additions (on top of the base `open5gs-docker-lab` repo)

```
core/
  smf.yaml     — added "ims" DNN session (subnet 10.46.0.0/16, p-cscf: 10.33.33.7)
  upf.yaml     — added matching "ims" DNN session (dev: ogstun2)
  start.sh     — added ogstun2 tuntap setup + MASQUERADE for 10.46.0.0/16
ueransim/
  ue.yaml      — added second session: apn "ims"
  ue2.yaml     — second virtual UE (IMSI 999700000000002), same structure
ims/
  Dockerfile   — Debian bookworm-slim + kamailio + iproute2/iputils-ping
  entrypoint.sh— adds a route to 10.46.0.0/16 via core, then execs kamailio
  kamailio.cfg — minimal registrar/proxy (no HSS/Diameter, no auth challenge)
baresip/
  Dockerfile   — Debian bookworm-slim + baresip
  entrypoint.sh— detects the ims tun interface, writes config+accounts, execs baresip
docker-compose.yml — added services: ims, ue2, sipclient1, sipclient2
```

## Subscriber requirements

Both IMSIs need an `ims` session entry in their Mongo subscriber document,
in addition to `internet`:

```js
// example shape pushed into slice.0.session
{
  name: "ims",
  type: NumberInt(3),
  qos: { index: NumberInt(5), arp: { priority_level: NumberInt(8),
         pre_emption_capability: NumberInt(1), pre_emption_vulnerability: NumberInt(1) } },
  ambr: { downlink: { value: NumberInt(1), unit: NumberInt(3) },
          uplink:   { value: NumberInt(1), unit: NumberInt(3) } }
}
```

## Gotchas fixed (read before touching configs again)

| Symptom | Root cause | Fix |
|---|---|---|
| Kamailio: `error searching pvar "avp"` / crash on `siputils` init | `siputils` module's built-in `rpid_avp` default uses an AVP syntax this Kamailio build doesn't support, and it's parsed at `mod_init` regardless of whether you use it | Don't load `siputils`; replace `has_totag()` with a plain `loose_route()` call (it already no-ops safely with no Route header) |
| `unknown command, missing loadmodule?` on `has_totag` | Removed `siputils` entirely without realizing `has_totag()` lives there | See above — avoid needing the function at all instead of re-adding the broken module |
| `ogstun2` up but no IP / state DOWN | A `sed` insert landed between an `iptables ... \|\| \` line and its continuation, silently changing what ran conditionally vs unconditionally | Don't patch multi-line shell continuations with `sed -i /pattern/a`; rewrite the whole script cleanly instead |
| UE pings `10.33.33.7` (Kamailio) — 100% packet loss | No NAT/route existed for the new `ims` subnet; `internet`'s DNN only worked because of its own MASQUERADE rule | Add `iptables -t nat -A POSTROUTING -s 10.46.0.0/16 ! -o ogstun2 -j MASQUERADE` to `start.sh`, same pattern as `internet` |
| Call rings but times out (`408 Request Timeout`); REGISTER works fine | Kamailio can relay because MASQUERADE makes REGISTER *replies* return to `core`'s own IP (which Kamailio can reach) — but a **new** INVITE Kamailio initiates *toward* `10.46.0.x` has no route at all | Add a static route inside the `ims` container: `ip route add 10.46.0.0/16 via 10.33.33.4` |
| Route/ping commands fail in `ims` container: `ip`/`ping` not found | Minimal Debian image only had `kamailio` installed | Add `iproute2 iputils-ping` to the `ims` Dockerfile |
| `kamctl ul show` fails: `Error opening Kamailio's FIFO` | `pipe_name` is an `mi_fifo` module parameter, not `jsonrpcs`'s — wrong module entirely | Don't bother with `kamctl`; use baresip's own `/uanew` + `/reginfo` as ground truth instead |
| baresip: `conf: could not get config path` | `$HOME` unset in the minimal container | `export HOME=/root` and pass `-f /root/.baresip` explicitly |
| baresip: `dl: mod: ./stdio.so ... No such file` | Modules referenced by relative path; Debian installs them elsewhere | Add `module_path /usr/lib/baresip/modules` before any `module` lines |
| baresip: 0 User Agents even with a correct `accounts` file and `accounts_path` set | The actual module responsible for reading the accounts file (`account.so`) was never loaded — an unrecognized/missing-module dependency, not a config syntax issue | Add `module account.so` |
| baresip call connects but audio fails: `ausine: supports only 48kHz samplerate` | `ausine` (synthetic tone source) only runs at 48kHz; call negotiated PCMU (8kHz, from `g711`) | Load `opus.so` (48kHz-capable) **before** `g711.so` — this build prioritizes codecs by **module load order**, not the `audio_codecs` config directive |
| Account loads via CLI (`/uanew`) but not from the accounts file at boot | Leftover `;mediaenc=none` param — CLI account creation tolerates it with a warning, file-based loading may not | Drop `;mediaenc=none` from the accounts file entirely |

## Running the demo

Bring the stack up (idempotent if already running):
```bash
cd ~/open5gs-docker-lab
docker compose up -d
sleep 15
```

Open two terminals to the Pi, one per virtual phone:
```bash
# Terminal A
docker attach open5gs-docker-lab-sipclient1-1
# Terminal B
docker attach open5gs-docker-lab-sipclient2-1
```

Confirm both auto-registered (type in each):
```
/reginfo
```
Want `OK ... Expires 300s` on both sides — no manual `/uanew` needed anymore.

Place the call, in Terminal A:
```
/dial sip:1002@ims.mnc070.mcc999.3gppnetwork.org
```

Answer it in Terminal B if it doesn't auto-answer:
```
a
```

Confirm it's live, in either terminal:
```
/callstat
```
Want `Call established` and a climbing bitrate (e.g. `audio=99400/0 (bit/s)`).

Hang up:
```
/hangup
```

**Detach from a terminal without killing the container:** Ctrl-P then Ctrl-Q — never Ctrl-C.

For a live audience, run a third terminal alongside showing the underlying
signaling:
```bash
docker compose logs -f ims
docker compose logs -f gnb ue ue2
```
so people can see real NGAP/PDU-session/SIP REGISTER-INVITE traffic while
the call happens, not just two SIP clients talking.

## Troubleshooting quick reference

| Symptom | Check |
|---|---|
| UE only shows one tun interface | `ueransim/ue.yaml` or `ue2.yaml` missing the second `sessions:` entry for `apn: ims` |
| PDU session for `ims` rejected | Subscriber's `slice.0.session` array missing the `"ims"` entry in Mongo |
| Call rings but never connects | `ims` container's static route to `10.46.0.0/16` missing (check `docker compose exec ims ip route`) |
| No audio despite `Call established` | Check `docker compose logs sipclient1 \| grep -i opus` — module load order matters, `opus.so` must precede `g711.so` |
| sipclient shows 0 User Agents after a rebuild | `account.so` not in the `module` list, or a bad param snuck back into the accounts file |
| Restarting `core` breaks everything downstream | Same as the base lab: restart in order — `core` → `gnb` → `ue`/`ue2` → `ims` (if also recreated) |

## Backup / rollback

Same approach as the base lab's `MIGRATE.md` — tag known-good states in git
and snapshot the Mongo volume before risky changes:
```bash
git add -A && git commit -m "..." && git push
git tag <checkpoint-name> && git push --tags
docker run --rm -v open5gs-docker-lab_mongo-data:/data -v "$PWD":/backup \
  busybox tar czf /backup/mongo-data-<checkpoint-name>.tar.gz -C /data .
```
Checkpoints already pushed during this build: `pre-ims-baseline`,
`ims-core-working`, `ims-call-working`, `ims-auto-register-working`.
