import { eq } from "drizzle-orm";
import { db } from "@/db";
import { device } from "@/db/schema";
import { hashToken } from "@/lib/signing";

export interface AuthedDevice {
  id: string;
  userId: string;
  signingSecret: string;
}

/** Resolve `Authorization: Bearer <deviceToken>` to a live device row. */
export async function authenticateDevice(
  req: Request
): Promise<AuthedDevice | null> {
  const header = req.headers.get("authorization") ?? "";
  const match = /^Bearer\s+(.+)$/i.exec(header.trim());
  if (!match) return null;
  const token = match[1].trim();
  if (!token) return null;

  const rows = await db
    .select()
    .from(device)
    .where(eq(device.tokenHash, hashToken(token)))
    .limit(1);

  const row = rows[0];
  if (!row || row.revokedAt) return null;

  // Best-effort last-seen; don't block the request on it.
  void db
    .update(device)
    .set({ lastSeenAt: new Date() })
    .where(eq(device.id, row.id))
    .catch(() => {});

  return { id: row.id, userId: row.userId, signingSecret: row.signingSecret };
}
