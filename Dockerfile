FROM node:24-alpine

WORKDIR /app

ENV NODE_ENV=production

COPY package*.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY dist/ ./dist/

USER node

EXPOSE 3000

CMD ["node", "dist/main.js"]
