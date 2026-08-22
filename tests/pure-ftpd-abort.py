#!/usr/bin/env python3
"""Prove that an aborted upload is not published under its final name.

    tests/pure-ftpd-abort.py ftp://cameras:cameras@10.0.0.101/

1. STOR a file, send half of it, then reset the data connection (SO_LINGER 0
   -> TCP RST), which is what a camera with a dying Wi-Fi link does. Expect a
   451 and NO file under the final name. Stock pure-ftpd -0 publishes the
   partial here, so this check fails against an unpatched server — by design.
2. STOR the same file completely. Expect 226 and the file listed, then DELE it.

The name ends in .part so the sorter ignores it if cleanup ever fails.
"""
import ftplib
import io
import os
import socket
import struct
import sys
import urllib.parse

NAME = "ftpdropbox-abort-test.part"
CHUNK = os.urandom(1024 * 1024)
CHUNKS = 8


def connect(url):
    ftp = ftplib.FTP()
    ftp.connect(url.hostname, url.port or 21, timeout=60)
    ftp.login(url.username or "anonymous", url.password or "")
    return ftp


def listed(ftp):
    return any(line.rsplit("/", 1)[-1] == NAME for line in ftp.nlst())


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    url = urllib.parse.urlsplit(sys.argv[1])

    # 1. abort mid-upload with a TCP reset
    ftp = connect(url)
    ftp.voidcmd("TYPE I")
    data = ftp.transfercmd(f"STOR {NAME}")
    for _ in range(CHUNKS // 2):
        data.sendall(CHUNK)
    data.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    data.close()
    try:
        resp = ftp.getresp()
    except ftplib.error_temp as exc:
        resp = str(exc)
    assert resp.startswith("451"), f"expected 451 after the reset, got: {resp!r}"
    if listed(ftp):
        try:
            ftp.delete(NAME)
        finally:
            sys.exit(f"FAIL: aborted upload was published as {NAME} (stock pure-ftpd behaviour)")
    ftp.quit()

    # 2. a completed upload still lands
    ftp = connect(url)
    ftp.storbinary(f"STOR {NAME}", io.BytesIO(CHUNK * CHUNKS))
    assert listed(ftp), f"FAIL: completed upload {NAME} is not listed"
    ftp.delete(NAME)
    ftp.quit()
    print("PASS: aborted upload not published; completed upload landed")


if __name__ == "__main__":
    main()
