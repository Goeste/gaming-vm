FROM ghcr.io/home-assistant/base:3.24

RUN apk add --no-cache python3 py3-flask py3-requests openssh-client

COPY app /app
COPY run.sh /run.sh
RUN chmod a+x /run.sh

CMD [ "/run.sh" ]
