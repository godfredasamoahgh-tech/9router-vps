FROM node:22-alpine

WORKDIR /app

RUN npm install -g 9router@0.5.81

ENV PORT=20128
ENV HOSTNAME=0.0.0.0
ENV DATA_DIR=/app/data
ENV NODE_ENV=production

EXPOSE 20128

CMD ["9router", "start", "--port", "20128", "--host", "0.0.0.0", "--skip-update"]
