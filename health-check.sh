#!/bin/bash
# Open5GS + UERANSIM + IMS lab health check
# Run from ~/open5gs-docker-lab on the Pi.
#
# Usage: ./health-check.sh
#
# Exits 0 if everything looks healthy, 1 if anything failed.

set -u
PASS=0
FAIL=0
WARN=0

ok()   { echo "  [OK]   $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN+1)); }

section() { echo; echo "=== $1 ==="; }

IMS_IP="10.33.33.7"

# ---------------------------------------------------------------------------
section "1. Container status"
# ---------------------------------------------------------------------------
EXPECTED_SERVICES="mongo core webui gnb ue ue2 ims sipclient1 sipclient2"
PS_OUT=$(docker compose ps --format json 2>/dev/null)

for svc in $EXPECTED_SERVICES; do
    state=$(echo "$PS_OUT" | grep -o "\"Service\":\"$svc\"[^}]*\"State\":\"[a-z]*\"" | grep -o '"State":"[a-z]*"' | cut -d'"' -f4)
    if [ "$state" = "running" ]; then
        ok "$svc container is running"
    else
        bad "$svc container state='${state:-not found}' (expected running)"
    fi
done

# ---------------------------------------------------------------------------
section "2. Core (AMF/SMF/UPF/NRF/UDR/UDM) health"
# ---------------------------------------------------------------------------
CORE_LOG=$(docker compose logs core --tail 200 2>/dev/null)

reject_count=$(echo "$CORE_LOG" | grep -c "Registration reject")
if [ "$reject_count" -gt 0 ]; then
    bad "core log shows $reject_count 'Registration reject' event(s) in last 200 lines"
    echo "$CORE_LOG" | grep "Registration reject" | tail -3 | sed 's/^/         /'
else
    ok "no registration rejects in recent core log"
fi

sbi500_count=$(echo "$CORE_LOG" | grep -c "\[500:")
if [ "$sbi500_count" -gt 5 ]; then
    bad "core log shows $sbi500_count SBI 500 errors in last 200 lines (stale registration-context state — try: docker compose restart core)"
elif [ "$sbi500_count" -gt 0 ]; then
    warn "core log shows $sbi500_count SBI 500 error(s) — watch for repeats"
else
    ok "no SBI 500 errors in recent core log"
fi

if echo "$CORE_LOG" | grep -q "NF instance registered\|NF Instance registered\|nrf.*registered"; then
    ok "core NFs registered with NRF"
else
    warn "could not confirm NRF registration from recent log tail (may just be outside the 200-line window)"
fi

# ---------------------------------------------------------------------------
section "3. gNB health"
# ---------------------------------------------------------------------------
GNB_LOG=$(docker compose logs gnb --tail 100 2>/dev/null)

if echo "$GNB_LOG" | grep -qi "NG Setup response\|NG Setup procedure is successful\|connected to AMF"; then
    ok "gnb: NG Setup with AMF successful"
else
    bad "gnb: no successful NG Setup found in recent log"
fi

sctp_retry=$(echo "$GNB_LOG" | grep -ci "SCTP could not connect\|Cell selection failure")
if [ "$sctp_retry" -gt 2 ]; then
    bad "gnb log shows $sctp_retry SCTP/cell-selection failures — likely the SCTP race (see Known Issue #1); check the fixed sleep-delay is still in docker-compose.yml"
elif [ "$sctp_retry" -gt 0 ]; then
    warn "gnb log shows $sctp_retry SCTP/cell-selection failure message(s), but recovered"
else
    ok "no SCTP connection failures in recent gnb log"
fi

# ---------------------------------------------------------------------------
section "4. UE data-plane health (ue / ue2)"
# ---------------------------------------------------------------------------
for ue_svc in ue ue2; do
    if [ "$ue_svc" = "ue" ]; then tun=uesimtun0; else tun=uesimtun1; fi

    if docker compose exec -T "$ue_svc" ip addr show "$tun" >/dev/null 2>&1; then
        ok "$ue_svc: $tun interface present (PDU session established)"
    else
        bad "$ue_svc: $tun interface NOT found (no PDU session)"
        continue
    fi

    ping_out=$(docker compose exec -T "$ue_svc" ping -c 3 -W 2 -I "$tun" "$IMS_IP" 2>&1)
    loss=$(echo "$ping_out" | grep -o '[0-9]*% packet loss' | grep -o '^[0-9]*')
    if [ "$loss" = "0" ]; then
        ok "$ue_svc: ping to $IMS_IP over $tun succeeded (0% loss)"
    else
        bad "$ue_svc: ping to $IMS_IP over $tun failed (${loss:-unknown}% loss) — data plane not traversing UPF/NAT; try: docker compose restart core"
    fi
done

# ---------------------------------------------------------------------------
section "5. IMS / SIP registration health"
# ---------------------------------------------------------------------------
for sc in sipclient1 sipclient2; do
    SC_LOG=$(docker compose logs "$sc" --tail 40 2>/dev/null)

    if echo "$SC_LOG" | grep -qi "Network is unreachable"; then
        bad "$sc: 'Network is unreachable' present — restart after ue/ue2 are confirmed up (Known Issue #2)"
        continue
    fi

    iface=$(echo "$SC_LOG" | grep -i "Detected ims interface" | tail -1)
    if echo "$iface" | grep -q "uesimtun"; then
        ok "$sc: registered via $(echo "$iface" | grep -o 'uesimtun[0-9]*') (genuine 5GC path)"
    elif echo "$iface" | grep -qi "eth0"; then
        bad "$sc: registered via eth0 — false positive, this is the Docker bridge shortcut, not the real 5GC path. Force-recreate: docker compose up -d --force-recreate $sc"
    else
        warn "$sc: could not determine which interface was used for registration (check manually)"
    fi

    if echo "$SC_LOG" | grep -qi "200 OK"; then
        ok "$sc: received 200 OK on REGISTER"
    else
        warn "$sc: no 200 OK seen in recent log tail — may just be outside the window"
    fi
done

# ---------------------------------------------------------------------------
section "Summary"
# ---------------------------------------------------------------------------
echo "  PASS=$PASS  WARN=$WARN  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
    echo "  Overall: HEALTHY"
    exit 0
else
    echo "  Overall: UNHEALTHY — see [FAIL] lines above"
    exit 1
fi
