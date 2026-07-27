#!/bin/bash
set -e
export HOME=/root
IMS_IF=$(ip -o addr show | awk '/inet 10\.46\./{print $2}' | head -1)
echo "Detected ims interface: ${IMS_IF}"
mkdir -p /root/.baresip
cat > /root/.baresip/config <<CFG
sip_listen         0.0.0.0:5060
sip_transports     udp
net_interface      ${IMS_IF}
module_path         /usr/lib/baresip/modules
module             opus.so
audio_codecs        opus/48000/2,PCMU/8000/1
accounts_path       /root/.baresip/accounts
audio_player       ausine
audio_source       ausine,440
audio_alert        ausine,880
module             stdio.so
module             ausine.so
module             g711.so
module_app         menu.so
CFG
cat > /root/.baresip/accounts <<ACC
<sip:${SIP_USER}@ims.mnc070.mcc999.3gppnetwork.org>;outbound="sip:10.33.33.7:5060";regint=300;mediaenc=none
ACC
exec baresip -v -f /root/.baresip
