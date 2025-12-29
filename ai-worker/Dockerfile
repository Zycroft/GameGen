FROM python:3.11-slim

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy worker script
COPY worker.py .

# Environment variables with defaults
ENV DYNAMODB_ENDPOINT=http://host.docker.internal:8001
ENV DYNAMODB_REGION=us-west-2
ENV OLLAMA_ENDPOINT=http://host.docker.internal:11434
ENV AI_PROMPTS_TABLE=AIPrompts
ENV POLL_INTERVAL=10
ENV REQUEST_TIMEOUT=600

# Run the worker
CMD ["python", "-u", "worker.py"]
