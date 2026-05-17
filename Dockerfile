FROM alpine:3.19
RUN apk add --no-cache bash inotify-tools exiftool coreutils findutils xxhash curl jq util-linux
COPY sort.sh /sort.sh
RUN chmod +x /sort.sh
CMD ["/sort.sh"]
