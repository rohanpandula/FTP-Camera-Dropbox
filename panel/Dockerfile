FROM python:3.12-alpine
# exiftool: embedded-preview extraction for the contact sheet.
# Pillow: downscale those previews so a strip of thumbs isn't 50 MB over LAN.
# pillow-heif: iPhone HEIC carries no JPEG item to extract, so Pillow needs a
# real HEIF decoder for it; the musllinux wheel bundles libheif. It needs
# Pillow >= 11.1.
RUN apk add --no-cache exiftool \
    && pip install --no-cache-dir "fastapi==0.115.*" "uvicorn==0.30.*" "pillow==11.*" "pillow-heif==1.6.*"
COPY app.py index.html /app/
COPY assets /app/assets/
USER 99:100
EXPOSE 8484
CMD ["python", "-m", "uvicorn", "--app-dir", "/app", "app:app", "--host", "0.0.0.0", "--port", "8484"]
