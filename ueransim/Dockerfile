FROM gradiant/ueransim:3.2.6

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        traceroute \
        iproute2 \
        python3 \
        python3-pip && \
    (pip3 install --no-cache-dir speedtest-cli || \
     pip3 install --no-cache-dir --break-system-packages speedtest-cli) && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
