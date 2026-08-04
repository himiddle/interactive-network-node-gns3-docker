FROM debian:latest

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    iproute2 \
    net-tools \
    iputils-ping \
    iputils-tracepath \
    tcpdump \
    traceroute \
    nano \
    curl \
    wget \
    isc-dhcp-client \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY setup-network.sh /usr/local/bin/setup-network.sh
RUN chmod +x /usr/local/bin/setup-network.sh

RUN echo "alias net='bash /usr/local/bin/setup-network.sh'" >> /root/.bashrc
RUN echo 'bash /usr/local/bin/setup-network.sh' >> /root/.bashrc

CMD ["/bin/bash", "--login"]
