FROM nginx:1.27-alpine

RUN apk add --no-cache \
    fcgiwrap \
    git \
    git-daemon \
    spawn-fcgi \
    apache2-utils \
    && git config --system http.receivepack true \
    && git config --system http.uploadpack true

COPY nginx-default.conf /etc/nginx/conf.d/default.conf
# Entrypoint is inlined (not COPY entrypoint.sh) so Kaniko + ConfigMap builds work.
# Keep in sync with docker/git-http-server/entrypoint.sh — see README.md Recovery section.
RUN printf '%s\n' \
    '#!/bin/sh' \
    'set -eu' \
    '' \
    'FCGI_SOCKET=/var/run/fcgiwrap.sock' \
    'FCGI_PROGRAM=/usr/bin/fcgiwrap' \
    '' \
    'mkdir -p /srv/git' \
    'chown -R nginx:nginx /srv/git' \
    '' \
    'spawn-fcgi \' \
    '    -s "${FCGI_SOCKET}" \' \
    '    -F 2 \' \
    '    -u nginx \' \
    '    -g nginx \' \
    '    -U nginx \' \
    '    -G nginx \' \
    '    -- \' \
    '    "${FCGI_PROGRAM}"' \
    '' \
    "exec nginx -g 'daemon off;'" \
    > /entrypoint.sh \
    && chmod +x /entrypoint.sh

EXPOSE 80
ENTRYPOINT ["/entrypoint.sh"]
