FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y kamailio && rm -rf /var/lib/apt/lists/*
COPY kamailio.cfg /etc/kamailio/kamailio.cfg
CMD ["kamailio", "-DD", "-E"]
