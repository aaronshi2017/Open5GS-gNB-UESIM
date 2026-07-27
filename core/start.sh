#!/bin/bash
set -e
ETC=/opt/open5gs/etc/open5gs
BIN=/opt/open5gs/bin
mkdir -p /opt/open5gs/var/log/open5gs

cp /config/*.yaml "$ETC"/

ip tuntap add name ogstun mode tun
ip addr add 10.45.0.1/16 dev ogstun
ip link set ogstun up
iptables -t nat -A POSTROUTING -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE

ip tuntap add name ogstun2 mode tun
ip addr add 10.46.0.1/16 dev ogstun2
ip link set ogstun2 up
iptables -t nat -A POSTROUTING -s 10.46.0.0/16 ! -o ogstun2 -j MASQUERADE

"$BIN"/open5gs-nrfd -d & sleep 2
"$BIN"/open5gs-scpd -d & sleep 2
for nf in ausf udm udr pcf bsf nssf; do "$BIN"/open5gs-${nf}d -d & done
sleep 3
"$BIN"/open5gs-upfd -d & sleep 2
"$BIN"/open5gs-smfd -d & sleep 2
"$BIN"/open5gs-amfd -d &

echo "=== Open5GS started: AMF NGAP on 10.33.33.4:38412, UPF GTP-U on 10.33.33.4:2152 ==="
sleep infinity
