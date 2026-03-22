FROM node:24-alpine

WORKDIR /app

COPY src/package*.json ./
RUN npm install --production

COPY ./src .

# this is just documentation apparently
EXPOSE 3000

CMD ["node", "server.js"]
