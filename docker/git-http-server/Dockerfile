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
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80
ENTRYPOINT ["/entrypoint.sh"]
