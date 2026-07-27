FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y kamailio iproute2 iputils-ping && rm -rf /var/lib/apt/lists/*
COPY kamailio.cfg /etc/kamailio/kamailio.cfg
RUN mkdir -p /run/kamailio
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
