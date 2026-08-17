import { createHash, createHmac, randomBytes, timingSafeEqual } from "crypto";

/** Opaque device token handed to the app; we persist only its hash. */
export function newDeviceToken(): string {
  // 32 bytes -> 43 url-safe chars. Prefixed so it's greppable in logs/support.
  return "ist_" + randomBytes(32).toString("base64url");
}

/** Per-device HMAC secret (base64url, 32 bytes). */
export function newSigningSecret(): string {
  return randomBytes(32).toString("base64url");
}

export function hashToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

/**
 * Stripe-webhook-style signature over `${timestamp}.${rawBody}`.
 * Header format: `X-Signature: t=<unixSeconds>,v1=<hexHmacSha256>`
 *
 * NOTE: the secret lives on the client, so this proves the payload came from a
 * device holding that secret and was not altered in transit — it does NOT prove
 * the numbers are truthful (the legitimate owner can always sign forged data).
 */
export function verifySignature(opts: {
  header: string | null;
  rawBody: string;
  secret: string;
  toleranceSeconds?: number;
  nowSeconds?: number;
}): { ok: true } | { ok: false; reason: string } {
  const { header, rawBody, secret } = opts;
  const tolerance = opts.toleranceSeconds ?? 300;
  const now = opts.nowSeconds ?? Math.floor(Date.now() / 1000);

  if (!header) return { ok: false, reason: "missing signature header" };

  let t: number | undefined;
  let v1: string | undefined;
  for (const part of header.split(",")) {
    const [k, v] = part.split("=", 2);
    if (k?.trim() === "t") t = Number(v);
    if (k?.trim() === "v1") v1 = v?.trim();
  }
  if (!t || !Number.isFinite(t) || !v1) {
    return { ok: false, reason: "malformed signature header" };
  }
  if (Math.abs(now - t) > tolerance) {
    return { ok: false, reason: "signature timestamp outside tolerance" };
  }

  const expected = createHmac("sha256", secret)
    .update(`${t}.${rawBody}`)
    .digest("hex");

  const a = Buffer.from(expected, "utf8");
  const b = Buffer.from(v1, "utf8");
  if (a.length !== b.length || !timingSafeEqual(a, b)) {
    return { ok: false, reason: "signature mismatch" };
  }
  return { ok: true };
}
