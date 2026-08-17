import { headers } from "next/headers";
import { NextResponse } from "next/server";
import { auth } from "@/auth";
import { db } from "@/db";
import { device } from "@/db/schema";
import { hashToken, newDeviceToken, newSigningSecret } from "@/lib/signing";

// GET /api/device/connect
// Requires a live browser session (set by Google sign-in). Mints a device
// credential and hands the opaque token back to the Mac app via its custom URL
// scheme. The signing secret is NOT put in the URL — the app fetches it over
// HTTPS from /api/device/provision using this token.
export async function GET() {
  const session = await auth.api.getSession({ headers: await headers() });
  if (!session) {
    return NextResponse.redirect(new URL("/connect", process.env.BETTER_AUTH_URL));
  }

  const token = newDeviceToken();
  const ua = (await headers()).get("user-agent") ?? undefined;

  await db.insert(device).values({
    id: crypto.randomUUID(),
    userId: session.user.id,
    tokenHash: hashToken(token),
    signingSecret: newSigningSecret(),
    label: ua?.slice(0, 200),
    createdAt: new Date(),
  });

  const scheme = process.env.APP_URL_SCHEME ?? "inputstats";
  const target = `${scheme}://connected?token=${encodeURIComponent(token)}`;
  return NextResponse.redirect(target);
}
