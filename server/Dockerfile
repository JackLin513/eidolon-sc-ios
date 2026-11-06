# 只服务自己人的小服务（spec #120）。数据都在 /data：SQLite 库和包文件。
FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY eidolon_server ./eidolon_server

ENV EIDOLON_SERVER_DB=/data/eidolon.sqlite3 \
    EIDOLON_SERVER_PACKAGES=/data/packages

VOLUME ["/data"]
EXPOSE 9090
CMD ["uvicorn", "eidolon_server.asgi:app", "--host", "0.0.0.0", "--port", "9090"]
