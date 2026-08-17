// TypeScript mirror of the Swift `SyncData` shape (Sources/Models.swift).
// Kept structurally identical so the same JSON round-trips through the Mac app,
// iCloud, and Postgres unchanged.

export interface DailyCount {
  count: number;
  lastModified: number; // seconds since epoch
  appCounts?: Record<string, number> | null; // bundleID -> count
}

export interface DeviceData {
  dailyCounts: Record<string, DailyCount>; // "yyyy-MM-dd" -> DailyCount
}

export interface SyncData {
  devices: Record<string, DeviceData>; // deviceID -> DeviceData
  version: number;
}

export function emptySyncData(): SyncData {
  return { devices: {}, version: 2 };
}

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

// Plausibility ceilings. A human physically cannot exceed these; anything above
// is forged or a bug, so we reject the whole request rather than store garbage.
export const LIMITS = {
  maxCountPerDay: 5_000_000, // ~keystrokes+mouse events in a day, generous
  maxAppsPerDay: 2_000,
  maxDaysPerDevice: 800,
  maxDevices: 64,
  futureSkewDays: 2, // allow for timezone differences
  maxPastDays: 800,
};

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

/**
 * Validate + clamp an untrusted SyncData payload from a client. Returns a
 * cleaned copy or an error describing the first violation. This is the part
 * that actually deters casual forgery (crypto can't, since the client holds
 * the key).
 */
export function sanitizeSyncData(
  input: unknown,
  nowMs = Date.now()
): { ok: true; data: SyncData } | { ok: false; reason: string } {
  if (!isPlainObject(input)) return { ok: false, reason: "not an object" };
  const devicesIn = input.devices;
  if (!isPlainObject(devicesIn)) {
    return { ok: false, reason: "devices missing" };
  }

  const deviceIds = Object.keys(devicesIn);
  if (deviceIds.length > LIMITS.maxDevices) {
    return { ok: false, reason: "too many devices" };
  }

  const today = new Date(nowMs);
  const maxDate = new Date(nowMs + LIMITS.futureSkewDays * 86400_000);
  const minDate = new Date(nowMs - LIMITS.maxPastDays * 86400_000);
  const maxKey = ymd(maxDate);
  const minKey = ymd(minDate);
  void today;

  const out: SyncData = emptySyncData();

  for (const deviceId of deviceIds) {
    if (deviceId.length === 0 || deviceId.length > 128) {
      return { ok: false, reason: "bad device id" };
    }
    const dd = devicesIn[deviceId];
    if (!isPlainObject(dd) || !isPlainObject(dd.dailyCounts)) {
      return { ok: false, reason: "bad device data" };
    }
    const daily = dd.dailyCounts as Record<string, unknown>;
    const dates = Object.keys(daily);
    if (dates.length > LIMITS.maxDaysPerDevice) {
      return { ok: false, reason: "too many days" };
    }

    const cleanDevice: DeviceData = { dailyCounts: {} };
    for (const date of dates) {
      if (!DATE_RE.test(date)) {
        return { ok: false, reason: `bad date key: ${date}` };
      }
      if (date > maxKey) return { ok: false, reason: `future date: ${date}` };
      if (date < minKey) continue; // silently drop ancient rows

      const dc = daily[date];
      if (!isPlainObject(dc)) return { ok: false, reason: "bad daily count" };
      const count = dc.count;
      if (typeof count !== "number" || !Number.isFinite(count) || count < 0) {
        return { ok: false, reason: "bad count" };
      }
      if (count > LIMITS.maxCountPerDay) {
        return { ok: false, reason: `count too large on ${date}` };
      }

      let appCounts: Record<string, number> | null = null;
      if (dc.appCounts != null) {
        if (!isPlainObject(dc.appCounts)) {
          return { ok: false, reason: "bad appCounts" };
        }
        const apps = Object.keys(dc.appCounts);
        if (apps.length > LIMITS.maxAppsPerDay) {
          return { ok: false, reason: "too many apps" };
        }
        appCounts = {};
        for (const bundle of apps) {
          const c = (dc.appCounts as Record<string, unknown>)[bundle];
          if (typeof c !== "number" || !Number.isFinite(c) || c < 0) {
            return { ok: false, reason: "bad app count" };
          }
          if (bundle.length > 256) {
            return { ok: false, reason: "bad bundle id" };
          }
          appCounts[bundle] = Math.floor(c);
        }
      }

      const rawLm = dc.lastModified;
      const lastModified: number =
        typeof rawLm === "number" && Number.isFinite(rawLm)
          ? rawLm
          : Math.floor(nowMs / 1000);

      cleanDevice.dailyCounts[date] = {
        count: Math.floor(count),
        lastModified,
        appCounts: appCounts && Object.keys(appCounts).length ? appCounts : null,
      };
    }
    out.devices[deviceId] = cleanDevice;
  }

  return { ok: true, data: out };
}

/**
 * Merge `incoming` into `base`, mirroring Swift `SyncData.merge`:
 * per (device, day) the higher count wins; on a tie, app counts are unioned by
 * max. Order-independent and idempotent.
 */
export function mergeSyncData(base: SyncData, incoming: SyncData): SyncData {
  const out: SyncData = {
    version: Math.max(base.version || 2, incoming.version || 2),
    devices: structuredClone(base.devices),
  };
  for (const [deviceId, incDevice] of Object.entries(incoming.devices)) {
    const cur = (out.devices[deviceId] ??= { dailyCounts: {} });
    for (const [date, incDay] of Object.entries(incDevice.dailyCounts)) {
      const existing = cur.dailyCounts[date];
      if (!existing) {
        cur.dailyCounts[date] = incDay;
      } else if (incDay.count > existing.count) {
        cur.dailyCounts[date] = incDay;
      } else if (incDay.count === existing.count) {
        const merged: Record<string, number> = { ...(existing.appCounts ?? {}) };
        for (const [b, c] of Object.entries(incDay.appCounts ?? {})) {
          merged[b] = Math.max(merged[b] ?? 0, c);
        }
        cur.dailyCounts[date] = {
          ...existing,
          appCounts: Object.keys(merged).length ? merged : null,
        };
      }
    }
  }
  return out;
}

function ymd(d: Date): string {
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, "0");
  const day = String(d.getUTCDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}
