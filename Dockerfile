FROM alpine:3.24.1
RUN apk add --no-cache bash inotify-tools exiftool coreutils findutils curl jq util-linux libraw-tools \
    && install -d -m 0700 -o 99 -g 100 /var/lib/camera-sorter
COPY sort.sh /sort.sh
RUN chmod +x /sort.sh
USER 99:100
CMD ["/sort.sh"]
