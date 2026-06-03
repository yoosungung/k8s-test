#!/bin/sh
set -eu

FCGI_SOCKET=/var/run/fcgiwrap.sock
FCGI_PROGRAM=/usr/bin/fcgiwrap

mkdir -p /srv/git
chown -R nginx:nginx /srv/git

spawn-fcgi \
    -s "${FCGI_SOCKET}" \
    -F 2 \
    -u nginx \
    -g nginx \
    -U nginx \
    -G nginx \
    -- \
    "${FCGI_PROGRAM}"

exec nginx -g 'daemon off;'
