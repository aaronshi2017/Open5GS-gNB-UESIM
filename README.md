# Open5GS + UERANSIM Docker Lab (Raspberry Pi 4)

Proves the full 5G SA flow (NG Setup → registration → PDU session → data) with a
simulated gNB and UE before connecting real Ericsson hardware. Later, the Ericsson
gNB simply replaces the `gnb` + `ue` containers, pointing at the same AMF.

## Containers

| Container | Image | Role |
|---|---|---|
| core | gradiant/open5gs | All Open5GS NFs in one container (AMF, SMF, UPF, NRF, SCP, AUSF, UDM, UDR, PCF, BSF, NSSF) |
| gnb | gradiant/ueransim | Simulated gNB (N2 → 10.33.33.4:38412, N3 GTP-U) |
| ue | gradiant/ueransim | Simulated UE (creates `uesimtun0`) |
| mongo | mongo:4.4.18 | Subscriber DB. **Must stay 4.4.x on Pi 4** (CPU lacks ARMv8.2, MongoDB ≥5 crashes) |
| webui | gradiant/open5gs-webui | Subscriber provisioning at http://\<pi\>:9999 |

Network: `10.33.33.0/24` (core .4, gnb .5, ue .6). UE pool: `10.45.0.0/16`.

## Prerequisites

- Pi 4 (4/8 GB) with **64-bit** OS (Ubuntu Server 22.04/24.04 arm64 recommended)
- Docker: `curl -fsSL https://get.docker.com | sh` (+ `sudo usermod -aG docker $USER`)

## Run

```bash
# 1. Start DB + core + WebUI
docker compose up -d mongo webui core
docker compose logs -f core        # wait until all NFs are up

# 2. Provision the subscriber: http://<pi-ip>:9999  (admin / 1423)
#    IMSI: 999700000000001
#    K:    465B5CE8B199B49FAA5F0A2EE238A6BC
#    OPc:  E8ED289DEBA952E4283B54E88E6183CA   (type = OPc, not OP)
#    DNN:  internet, SST: 1

# 3. Start simulated RAN
docker compose up -d gnb
docker compose logs gnb            # expect: "NG Setup procedure is successful"
docker compose up -d ue
docker compose logs ue             # expect: registration + "PDU Session establishment is successful"

# 4. Data test through the tunnel
docker compose exec ue ping -c 3 -I uesimtun0 8.8.8.8
docker compose exec ue nr-cli imsi-999700000000001 -e status
```

## Troubleshooting

| Symptom | Check |
|---|---|
| gnb: NGSetupFailure | PLMN (999/70), TAC (1), SST (1) match between gnb.yaml and core/amf.yaml |
| ue: auth failure | K/OPc in WebUI exactly match ue.yaml; OPc not OP |
| PDU session fails | DNN `internet` provisioned for subscriber; smf.yaml session subnet |
| Session up, no internet | `ogstun` + MASQUERADE inside core (`docker compose exec core iptables -t nat -L`) |
| mongo restarts on Pi 4 | Wrong tag — must be 4.4.x |
| image has no arm64 | Build UERANSIM locally: `docker build -t ueransim:local ./ueransim` and swap image in compose |

## Notes

- Image tags move; verify current arm64 tags for `gradiant/open5gs`, `gradiant/open5gs-webui`,
  `gradiant/ueransim` on Docker Hub. Config format here targets Open5GS 2.7.x.
- To capture signalling: `docker compose exec core apt-get install -y tcpdump` then
  `tcpdump -i eth0 sctp -w /config/ngap.pcap` and open in Wireshark.
- Migration to real RAN: keep `core`, expose 38412/SCTP + 2152/UDP on the Pi's physical
  NIC (host networking or port mapping), point the Ericsson gNB at that IP, drop gnb/ue containers.
