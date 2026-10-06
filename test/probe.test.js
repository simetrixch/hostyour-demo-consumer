import assert from "node:assert/strict";
import { test } from "node:test";
import { makeProbe } from "../src/probe.js";

/** In-memory stand-ins for the two clients, answering the calls the probe makes. */
function fakes() {
  const keys = new Map();
  let table = null;
  const redis = { set: async (k, v) => { keys.set(k, v); }, get: async (k) => keys.get(k) ?? null, ping: async () => "PONG" };
  const sql = {
    async query(statement, params = []) {
      if (statement.startsWith("CREATE TABLE")) { table ??= new Map(); return [[]]; }
      if (statement.startsWith("INSERT")) { table.set(1, params[0]); return [[]]; }
      if (statement.startsWith("SELECT text")) {
        if (!table) throw Object.assign(new Error("no table"), { code: "ER_NO_SUCH_TABLE" });
        return [table.has(1) ? [{ text: table.get(1) }] : []];
      }
      return [[{ 1: 1 }]];
    },
  };
  return { redis, sql };
}

/** The proof the live test makes: what was written is read back from both stores. */
async function writesAndReadsBoth(probe) {
  await probe.write("2026-10-06 proof");
  assert.deepEqual(await probe.read(), { redis: "2026-10-06 proof", mariadb: "2026-10-06 proof" });
}

test("a written probe reads back from Redis and from MariaDB", async () => {
  await writesAndReadsBoth(makeProbe(fakes()));
});

test("an empty consumer reads null for both, a missing table included", async () => {
  assert.deepEqual(await makeProbe(fakes()).read(), { redis: null, mariadb: null });
});

test("PLANTED: a probe that writes Redis but not MariaDB fails the proof", async () => {
  const stores = fakes();
  const broken = { ...makeProbe(stores), write: async (text) => stores.redis.set("probe", text) };
  await assert.rejects(writesAndReadsBoth(broken));
});
