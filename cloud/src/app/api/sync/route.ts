import { NextResponse } from "next/server";
import { eq } from "drizzle-orm";
import { db } from "@/db";
import { syncBlob } from "@/db/schema";
import { authenticateDevice } from "@/lib/deviceAuth";
import { verifySignature } from "@/lib/signing";
import {
  emptySyncData,
  mergeSyncData,
  sanitizeSyncData,
  type SyncData,
} from "@/lib/syncdata";

async function loadBlob(userId: string): Promise<SyncData> {
  const rows = await db
    .select()
    .from(syncBlob)
    .where(eq(syncBlob.userId, userId))
    .limit(1);
  return (rows[0]?.data as SyncData) ?? emptySyncData();
}

// GET /api/sync -> the user's full merged blob (all their devices).
export async function GET(req: Request) {
  const dev = await authenticateDevice(req);
  if (!dev) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }
  const data = await loadBlob(dev.userId);
  return NextResponse.json({ data });
}

// POST /api/sync -> validate + verify signature + merge this device's data in,
// return the new merged blob. Body is a raw SyncData JSON.
export async function POST(req: Request) {
  const dev = await authenticateDevice(req);
  if (!dev) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  const raw = await req.text();

  const sig = verifySignature({
    header: req.headers.get("x-signature"),
    rawBody: raw,
    secret: dev.signingSecret,
  });
  if (!sig.ok) {
    return NextResponse.json({ error: sig.reason }, { status: 401 });
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return NextResponse.json({ error: "invalid json" }, { status: 400 });
  }

  const clean = sanitizeSyncData(parsed);
  if (!clean.ok) {
    return NextResponse.json({ error: clean.reason }, { status: 422 });
  }

  const base = await loadBlob(dev.userId);
  const merged = mergeSyncData(base, clean.data);

  await db
    .insert(syncBlob)
    .values({ userId: dev.userId, data: merged, version: merged.version })
    .onConflictDoUpdate({
      target: syncBlob.userId,
      set: { data: merged, version: merged.version, updatedAt: new Date() },
    });

  return NextResponse.json({ data: merged });
}
