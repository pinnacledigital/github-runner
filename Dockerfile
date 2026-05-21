FROM myoung34/github-runner:latest

ENV DEBIAN_FRONTEND=noninteractive
ENV ANDROID_HOME=/opt/android/sdk
ENV ANDROID_SDK_ROOT=/opt/android/sdk
ENV JAVA_HOME=/usr/lib/jvm/temurin-17-jdk-amd64
ENV PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${JAVA_HOME}/bin:${PATH}"

# Java 17 Temurin
RUN apt-get update && \
    apt-get install -y wget apt-transport-https gnupg unzip python3 curl && \
    wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public | \
      gpg --dearmor | tee /etc/apt/trusted.gpg.d/adoptium.gpg > /dev/null && \
    echo "deb https://packages.adoptium.net/artifactory/deb jammy main" \
      | tee /etc/apt/sources.list.d/adoptium.list && \
    apt-get update && \
    apt-get install -y temurin-17-jdk && \
    rm -rf /var/lib/apt/lists/*

# Node.js 24
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# Android SDK command-line tools
RUN mkdir -p ${ANDROID_HOME}/cmdline-tools && \
    curl -sSL https://dl.google.com/android/repository/commandlinetools-linux-12266719_latest.zip \
      -o /tmp/cmdline-tools.zip && \
    unzip -q /tmp/cmdline-tools.zip -d ${ANDROID_HOME}/cmdline-tools && \
    mv ${ANDROID_HOME}/cmdline-tools/cmdline-tools ${ANDROID_HOME}/cmdline-tools/latest && \
    rm /tmp/cmdline-tools.zip

# Android SDK components + NDK
# NDK is large (~1.5 GB) — remove this line if not building native code
RUN yes | sdkmanager --licenses > /dev/null 2>&1 || true && \
    sdkmanager \
      "platform-tools" \
      "build-tools;35.0.0" \
      "platforms;android-35" \
      "ndk;27.1.12297006"

# Gradle cache dir with open permissions so runner user can write
RUN mkdir -p /root/.gradle && chmod 777 /root/.gradle

# Token rotation entrypoint
COPY token-entrypoint.sh /token-entrypoint.sh
RUN chmod +x /token-entrypoint.sh && \
    apt-get update && apt-get install -y jq && rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["/token-entrypoint.sh"]
CMD ["./run.sh"]
