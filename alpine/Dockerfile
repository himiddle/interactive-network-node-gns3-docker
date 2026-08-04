FROM alpine:latest

ENV LANG=C.UTF-8

RUN apk update && apk add --no-cache \
    bash \
    iproute2 \
    net-tools \
    iputils \
    tcpdump \
    nano \
    curl \
    wget \
    dhcpcd \
    && rm -rf /var/cache/apk/*

RUN ln -s /usr/sbin/dhcpcd /usr/usr/sbin/dhclient 2>/dev/null || ln -s /usr/sbin/dhcpcd /usr/local/bin/dhclient

COPY setup-network.sh /usr/local/bin/setup-network.sh
RUN chmod +x /usr/local/bin/setup-network.sh

RUN echo "alias net='bash /usr/local/bin/setup-network.sh'" >> /etc/profile
RUN echo 'bash /usr/local/bin/setup-network.sh' >> /etc/profile

CMD ["/bin/bash", "--login"]
