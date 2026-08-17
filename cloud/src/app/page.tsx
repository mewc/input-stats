export default function Home() {
  return (
    <main
      style={{
        minHeight: "100dvh",
        display: "grid",
        placeItems: "center",
        fontFamily: "-apple-system, system-ui, sans-serif",
        background: "#0b0b0c",
        color: "#f5f5f7",
        textAlign: "center",
        padding: 24,
      }}
    >
      <div>
        <h1 style={{ fontSize: 28, marginBottom: 8 }}>Input Stats Cloud</h1>
        <p style={{ color: "#9a9aa2", maxWidth: 420, lineHeight: 1.5 }}>
          The sync backend for the Input Stats menu bar app. Open the app and
          choose “Sign in to sync” to connect your Google account.
        </p>
      </div>
    </main>
  );
}
