FROM node:24-alpine

WORKDIR /app

COPY src/package*.json ./
RUN npm install --production

COPY ./src .

RUN chown -R node:node /app
USER node

EXPOSE 3000

CMD ["node", "server.js"]
