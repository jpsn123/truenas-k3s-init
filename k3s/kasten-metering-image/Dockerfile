ARG BASE_IMAGE=gcr.io/kasten-images/metering:8.5.8

FROM $BASE_IMAGE AS base

FROM python:3.12-slim AS build
COPY --from=base /metering-server /metering-server.orig
RUN pip install --no-cache-dir pyelftools capstone
COPY patch.py /patch.py
RUN python3 /patch.py /metering-server.orig /metering-server

FROM $BASE_IMAGE
COPY --from=build --chmod=755 /metering-server /metering-server
