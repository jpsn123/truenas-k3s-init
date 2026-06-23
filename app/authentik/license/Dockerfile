FROM python:3.14-slim

ARG INSTALL_ID=30d3e9a6-726b-4cbb-bac6-869e0e8448aa

WORKDIR /out

RUN python -m pip install --no-cache-dir \
    cryptography==48.0.0 \
    PyJWT==2.11.0 \
    dacite==1.9.2 \
    Django==5.2.14

COPY . /out/

RUN if [ ! -f /out/public.pem ] || [ ! -f /out/intermediate.pem ] || [ ! -f /out/leaf.pem ] || [ ! -f /out/leaf.key.pem ]; then \
        python /out/generate_enterprise_license_sample.py certs; \
    fi \
    && python /out/generate_enterprise_license_sample.py jwt --install-id "${INSTALL_ID}" | tee /out/license.jwt

CMD ["sh", "-lc", "ls -l /out && printf '\nlicense.jwt:\n' && cat /out/license.jwt"]
