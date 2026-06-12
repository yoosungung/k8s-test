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
RUN cat > /entrypoint.sh << 'EOF'
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
EOF
RUN chmod +x /entrypoint.sh

EXPOSE 80
ENTRYPOINT ["/entrypoint.sh"]
