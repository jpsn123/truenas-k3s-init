ARG BASIC_IMAGE=""
FROM ${BASIC_IMAGE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG DEBIAN_FRONTEND=noninteractive

USER root

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ninja-build \
      clang \
      clangd \
      clang-format \
      clang-tidy \
      llvm \
      lld \
      lldb \
      gdbserver \
      valgrind \
      ccache \
      libc++-dev \
      libc++abi-dev \
    ; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p /workspace; \
    chown -R coder:coder /workspace /home/coder

USER coder
WORKDIR /home/coder

CMD ["/bin/bash"]