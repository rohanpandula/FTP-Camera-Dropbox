FROM python:3.12-alpine
WORKDIR /app
# exiftool: structural validation of RAW files before deleting upstream copy.
# If exiftool reports IFD warnings (the Adobe-strict, exiftool-lenient case),
# we keep the file on Frame.io so the user can recover from the UI trash.
RUN apk add --no-cache exiftool
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
