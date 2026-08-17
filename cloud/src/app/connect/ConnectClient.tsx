"use client";

import { useEffect, useState } from "react";
import { signIn } from "@/lib/authClient";

export function ConnectClient({
  signedIn,
  email,
}: {
  signedIn: boolean;
  email: string | null;
}) {
  const [handedOff, setHandedOff] = useState(false);

  useEffect(() => {
    if (signedIn && !handedOff) {
      setHandedOff(true);
      // Mint the device token and bounce into the app via its URL scheme.
      window.location.href = "/api/device/connect";
    }
  }, [signedIn, handedOff]);

  return (
    <main style={styles.wrap}>
      <div style={styles.card}>
        <h1 style={styles.h1}>Input Stats</h1>
        {!signedIn ? (
          <>
            <p style={styles.p}>Connect your account to sync stats to the cloud.</p>
            <button
              style={styles.button}
              onClick={() =>
                signIn.social({ provider: "google", callbackURL: "/connect" })
              }
            >
              Continue with Google
            </button>
          </>
        ) : (
          <>
            <p style={styles.p}>
              Signed in as <strong>{email}</strong>.
            </p>
            <p style={styles.muted}>
              Returning you to the app… If nothing happens, make sure Input Stats
              is installed, then{" "}
              <a href="/api/device/connect" style={styles.link}>
                click here
              </a>
              .
            </p>
          </>
        )}
      </div>
    </main>
  );
}

const styles: Record<string, React.CSSProperties> = {
  wrap: {
    minHeight: "100dvh",
    display: "grid",
    placeItems: "center",
    fontFamily:
      "-apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif",
    background: "#0b0b0c",
    color: "#f5f5f7",
  },
  card: {
    width: 360,
    padding: 32,
    borderRadius: 16,
    background: "#161618",
    border: "1px solid #26262a",
    textAlign: "center",
  },
  h1: { fontSize: 22, margin: "0 0 12px" },
  p: { fontSize: 15, lineHeight: 1.5, margin: "0 0 20px", color: "#d0d0d4" },
  muted: { fontSize: 13, lineHeight: 1.5, color: "#8a8a92" },
  link: { color: "#7aa2ff" },
  button: {
    width: "100%",
    padding: "12px 16px",
    borderRadius: 10,
    border: "none",
    background: "#fff",
    color: "#111",
    fontSize: 15,
    fontWeight: 600,
    cursor: "pointer",
  },
};
