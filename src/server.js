// The demo consumer's process: connects to its two data services with the connection strings the
// provisioner writes into the ServiceClaims' Secrets, and serves the requests of app.js on 8080.
import { createServer } from "node:http";
import { createClient } from "redis";
import mysql from "mysql2/promise";
import { makeProbe } from "./probe.js";
import { makeHandler } from "./app.js";

const required = (name) => {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is not set — it comes from the consumer's Secrets`);
  return value;
};

const redis = createClient({ url: required("REDIS_URI") });
redis.on("error", (err) => console.error(`redis: ${err.message}`));
await redis.connect();
const sql = mysql.createPool({ uri: required("DATABASE_URL"), connectionLimit: 2 });
const handler = makeHandler({ probe: makeProbe({ redis, sql }), token: required("PROBE_TOKEN"), log: (line) => console.error(line) });

createServer(handler).listen(8080, () => console.log("hostyour-demo-consumer listens on 8080"));
