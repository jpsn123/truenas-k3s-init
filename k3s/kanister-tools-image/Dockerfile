FROM gcr.io/kasten-images/kanister-tools:8.5.0
USER root
RUN curl -L "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" -o /usr/bin/kubectl && \
    chmod +x /usr/bin/kubectl && \
    mv /usr/local/bin/kopia /usr/local/bin/kopia.real
ADD --chmod=755 kopia-hook.sh /usr/local/bin/kopia
#ADD --chmod=755 cloudsend.sh /usr/local/bin/ # for debug
USER kanister