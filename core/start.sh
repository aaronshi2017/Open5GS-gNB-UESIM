#!/bin/bash
ETC=/opt/open5gs/etc/open5gs
BIN=/opt/open5gs/bin
cp /config/*.yaml "$ETC"/
mkdir -p /opt/open5gs/var/log/open5gs

ip tuntap add name ogstun mode tun
ip addr add 10.45.0.1/16 dev ogstun
ip link set ogstun up
iptables -t nat -A POSTROUTING -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE || \
  echo "WARN: iptables unavailable - UE will get IP but no internet"

$BIN/open5gs-nrfd -d & sleep 2
$BIN/open5gs-scpd -d & sleep 2
for nf in ausf udm udr pcf bsf nssf; do $BIN/open5gs-${nf}d -d & done
sleep 3
$BIN/open5gs-upfd -d & sleep 2
$BIN/open5gs-smfd -d & sleep 2
$BIN/open5gs-amfd -d &
echo "=== Open5GS started ==="
sleep infinity
