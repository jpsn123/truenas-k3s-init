FROM debian:12 AS builder

WORKDIR /sub

RUN apt update && apt install -y --no-install-recommends \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt


FROM debian:12

ENV PYTHONUNBUFFERED=1

WORKDIR /sub

RUN apt update && apt install -y --no-install-recommends \
    python3 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/lib/python3.10/dist-packages /usr/local/lib/python3.10/dist-packages
COPY main.py /sub/

CMD ["python3", "/sub/main.py"]