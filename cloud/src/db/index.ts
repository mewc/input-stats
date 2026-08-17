import { drizzle, type NodePgDatabase } from "drizzle-orm/node-postgres";
import { Pool } from "pg";
import * as schema from "./schema";

// Lazy singletons so `next build` can import route modules without a live
// DATABASE_URL; the connection is only established on first real query.
let _pool: Pool | undefined;
let _db: NodePgDatabase<typeof schema> | undefined;

export function getPool(): Pool {
  if (_pool) return _pool;
  const connectionString = process.env.DATABASE_URL;
  if (!connectionString) throw new Error("DATABASE_URL is not set");
  const needsSsl =
    /sslmode=require/.test(connectionString) ||
    process.env.NODE_ENV === "production";
  _pool = new Pool({
    connectionString,
    ssl: needsSsl ? { rejectUnauthorized: false } : undefined,
  });
  return _pool;
}

// Proxy that defers connecting until a method is actually called.
export const db = new Proxy({} as NodePgDatabase<typeof schema>, {
  get(_t, prop, receiver) {
    _db ??= drizzle(getPool(), { schema });
    return Reflect.get(_db, prop, receiver);
  },
});

export { schema };
