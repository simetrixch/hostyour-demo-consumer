# The demo consumer's image: the app and its two clients, run as the image's unprivileged user.
FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY src ./src
USER 1000:1000
EXPOSE 8080
CMD ["node", "src/server.js"]
