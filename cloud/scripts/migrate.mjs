// Runs generated SQL migrations against DATABASE_URL. Used as Railway's
// pre-deploy / release command so schema changes land before the app boots.
import { drizzle } from "drizzle-orm/node-postgres/index.js";
import { migrate } from "drizzle-orm/node-postgres/migrator.js";
import pg from "pg";

const connectionString = process.env.DATABASE_URL;
if (!connectionString) {
  console.error("DATABASE_URL is not set");
  process.exit(1);
}
const ssl = /sslmode=require/.test(connectionString) || process.env.NODE_ENV === "production"
  ? { rejectUnauthorized: false }
  : undefined;

const pool = new pg.Pool({ connectionString, ssl });
const db = drizzle(pool);
await migrate(db, { migrationsFolder: "./drizzle" });
await pool.end();
console.log("migrations applied");
