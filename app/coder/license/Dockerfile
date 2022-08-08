FROM python:3.14-slim

ARG SUB=admin@example.com
ARG ACCOUNT_TYPE=premium
ARG FEATURE_SET=premium
ARG DURATION_DAYS=36500
ARG GRACE_DAYS=30
ARG USER_LIMIT=0

WORKDIR /out

RUN python -m pip install --no-cache-dir \
    cryptography==48.0.0

COPY . /out/

RUN if [ ! -f /out/private.key ]; then \
        python /out/sign_license.py --generate-key --key-dir /out --output /out/license.txt \
            --sub "${SUB}" \
            --account-type "${ACCOUNT_TYPE}" \
            --feature-set "${FEATURE_SET}" \
            --duration-days "${DURATION_DAYS}" \
            --grace-days "${GRACE_DAYS}" \
            --user-limit "${USER_LIMIT}"; \
    else \
        python /out/sign_license.py --private-key /out/private.key --output /out/license.txt \
            --sub "${SUB}" \
            --account-type "${ACCOUNT_TYPE}" \
            --feature-set "${FEATURE_SET}" \
            --duration-days "${DURATION_DAYS}" \
            --grace-days "${GRACE_DAYS}" \
            --user-limit "${USER_LIMIT}"; \
    fi

CMD ["sh", "-lc", "ls -l /out && printf '\nlicense.txt:\n' && cat /out/license.txt"]
