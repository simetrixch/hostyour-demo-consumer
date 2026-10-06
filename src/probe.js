// The probe: one Redis key and one MariaDB row, written and read through the consumer's own data
// services, so a backup and a restore of the consumer can be proven by reading them back.

export const PROBE_KEY = "probe";
export const PROBE_TABLE = "probe";

/** The probe's two stores, injected so the handler can be tested without a server. */
export function makeProbe({ redis, sql }) {
  return {
    /** Write `text` as the Redis key and as the row id=1, creating the table where it is missing. */
    async write(text) {
      await redis.set(PROBE_KEY, text);
      await sql.query(`CREATE TABLE IF NOT EXISTS ${PROBE_TABLE} (id INT PRIMARY KEY, text VARCHAR(200) NOT NULL)`);
      await sql.query(`INSERT INTO ${PROBE_TABLE} (id, text) VALUES (1, ?) ON DUPLICATE KEY UPDATE text = VALUES(text)`, [text]);
    },
    /** Read both back; null for what is missing, so a half-restored consumer shows which half. */
    async read() {
      const fromRedis = await redis.get(PROBE_KEY);
      let fromSql = null;
      try {
        const [rows] = await sql.query(`SELECT text FROM ${PROBE_TABLE} WHERE id = 1`);
        fromSql = rows[0]?.text ?? null;
      } catch (err) {
        if (err?.code !== "ER_NO_SUCH_TABLE") throw err;
      }
      return { redis: fromRedis ?? null, mariadb: fromSql };
    },
    /** Whether both services answer. */
    async healthy() {
      await redis.ping();
      await sql.query("SELECT 1");
      return true;
    },
  };
}
