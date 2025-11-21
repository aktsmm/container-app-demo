FROM python:3.11-slim
# 文字化け防止: Debian 系では locales パッケージを導入し ja_JP.UTF-8 を生成
RUN apt-get update \
    && apt-get install -y --no-install-recommends locales \
    && sed -i '/ja_JP.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*
ENV LANG=ja_JP.UTF-8 \
    LC_ALL=ja_JP.UTF-8

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY src ./src
EXPOSE 8000
CMD ["gunicorn", "-w", "2", "-b", "0.0.0.0:8000", "src.app:app"]
