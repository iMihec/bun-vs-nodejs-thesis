FROM oven/bun:1-slim

WORKDIR /app

COPY package.json bun.lock* ./

RUN bun install

COPY . .

RUN bunx prisma generate --schema=/app/prisma/schema.prisma

EXPOSE 3001

CMD ["bun", "src/index.js"]