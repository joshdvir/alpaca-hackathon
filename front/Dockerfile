# syntax=docker/dockerfile:1
# check=error=true

FROM node:22-slim

WORKDIR /app

# Install deps first (cache layer)
COPY package.json package-lock.json* ./
RUN npm install

# Copy source (in dev, this is overridden by a volume mount in docker-compose)
COPY . .

EXPOSE 5173

# Default to bash. docker-compose.yml runs `npm run dev -- --host 0.0.0.0`.
CMD ["bash"]
