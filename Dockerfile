FROM debian:trixie-slim
ARG REPOSITORY_URL=https://github.com/deadcxap/wakemeops-mirror
LABEL org.opencontainers.image.source=$REPOSITORY_URL
RUN apt-get update && apt-get install -y --no-install-recommends \
        debmirror nginx-light gpg gpgv python3-minimal tini ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY wakemeops-keyring.asc /usr/share/keyrings/wakemeops.asc
RUN gpg --batch --dearmor --output /usr/share/keyrings/wakemeops.gpg /usr/share/keyrings/wakemeops.asc \
    && install -d -o 99 -g 100 /mirror
COPY nginx.conf /etc/nginx/nginx.conf
COPY mirror.py /usr/local/lib/mirror.py
COPY --chmod=755 entrypoint.sh /usr/local/bin/start-mirror
ENV MIRROR_ARCHITECTURES=amd64 HOME=/tmp
USER 99:100
VOLUME ["/mirror"]
EXPOSE 8080
HEALTHCHECK --interval=1m --timeout=5s --start-period=2h CMD ["python3", "-c", "from urllib.request import urlopen; urlopen('http://127.0.0.1:8080/wakemeops/dists/stable/InRelease', timeout=3).close()"]
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/start-mirror"]
