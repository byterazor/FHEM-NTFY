FROM docker.io/nginx:latest

COPY FHEM /usr/share/nginx/html/FHEM/
COPY controls_byterazor-fhem-ntfy.txt /usr/share/nginx/html/
COPY CHANGED /usr/share/nginx/html/
