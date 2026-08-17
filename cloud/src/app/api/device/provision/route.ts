import { NextResponse } from "next/server";
import { authenticateDevice } from "@/lib/deviceAuth";

// The macOS app calls this once, right after it receives its device token via
// the `inputstats://` redirect, to fetch its HMAC signing secret over HTTPS
// (so the secret never travels in a URL). Idempotent: same device -> same secret.
export async function POST(req: Request) {
  const dev = await authenticateDevice(req);
  if (!dev) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }
  return NextResponse.json({
    deviceId: dev.id,
    userId: dev.userId,
    signingSecret: dev.signingSecret,
  });
}
