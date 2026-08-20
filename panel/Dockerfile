FROM python:3.12-alpine
# exiftool: embedded-preview extraction for the contact sheet.
# Pillow: downscale those previews so a strip of thumbs isn't 50 MB over LAN.
RUN apk add --no-cache exiftool \
    && pip install --no-cache-dir "fastapi==0.115.*" "uvicorn==0.30.*" "pillow==10.*"
COPY app.py index.html /app/
USER 99:100
EXPOSE 8484
CMD ["python", "-m", "uvicorn", "--app-dir", "/app", "app:app", "--host", "0.0.0.0", "--port", "8484"]
