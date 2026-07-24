# Fallback: build UERANSIM from source on arm64 if no prebuilt image works.
# docker build -t ueransim:local ./ueransim   (then use image: ueransim:local in compose)
# Build takes ~15-25 min on a Pi 4.
FROM ubuntu:22.04 AS build
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    make gcc g++ cmake git libsctp-dev lksctp-tools iproute2 && \
    rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 https://github.com/aligungr/UERANSIM /UERANSIM
RUN cd /UERANSIM && make -j"$(nproc)"

FROM ubuntu:22.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    libsctp1 lksctp-tools iproute2 iputils-ping && rm -rf /var/lib/apt/lists/*
COPY --from=build /UERANSIM/build/nr-gnb /UERANSIM/build/nr-ue /UERANSIM/build/nr-cli /usr/local/bin/
CMD ["nr-gnb"]
