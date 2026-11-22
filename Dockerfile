# Public demo server for Delivery Court (Base Sepolia and Lasna testnets only).
FROM node:22-slim
WORKDIR /app
COPY offchain/package.json offchain/package-lock.json offchain/
RUN cd offchain && npm ci --omit=dev
COPY offchain/src offchain/src
COPY offchain/public offchain/public
COPY model/judge.json model/model.json model/content_model.json model/seller_schemas.json model/
COPY deployments deployments
ENV NODE_ENV=production PORT=8080 DATA_DIR=/data
EXPOSE 8080
CMD ["node", "offchain/src/server.mjs"]
