FROM jenkins/jenkins:lts-jdk21

USER root
ARG NODE_VERSION=20.19.5

COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl git gh jq python3 python3-pip sqlite3 procps xz-utils \
      libasound2 libatk-bridge2.0-0 libatk1.0-0 libcups2 libdbus-1-3 \
      libdrm2 libgbm1 libglib2.0-0 libnspr4 libnss3 libpango-1.0-0 \
      libx11-6 libxcb1 libxcomposite1 libxdamage1 libxext6 libxfixes3 \
      libxkbcommon0 libxrandr2 fonts-liberation \
    && rm -rf /var/lib/apt/lists/*

RUN arch="$(dpkg --print-architecture)" \
    && case "$arch" in amd64) node_arch=x64 ;; arm64) node_arch=arm64 ;; *) exit 1 ;; esac \
    && curl --fail --location --silent --show-error \
      "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" \
      --output /tmp/node.tar.xz \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
    && rm /tmp/node.tar.xz \
    && node --version \
    && npm --version

RUN mkdir -p /var/jenkins_home/caches/npm /var/jenkins_home/caches/ms-playwright /var/jenkins_home/caches/qodo \
    && chown -R jenkins:jenkins /var/jenkins_home/caches

USER jenkins
