# SpirCore SaaS API -- deployable to any cloud (no MetaTrader5 dependency).
FROM python:3.11-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# SQLite file lives on a volume so data survives restarts.
ENV SAAS_DB=/data/saas.db
VOLUME ["/data"]
EXPOSE 9000

# SAAS_ADMIN_TOKEN must be provided at runtime (docker run -e ...).
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "9000"]
