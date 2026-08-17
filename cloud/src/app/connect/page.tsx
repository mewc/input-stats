import { headers } from "next/headers";
import { auth } from "@/auth";
import { ConnectClient } from "./ConnectClient";

export const dynamic = "force-dynamic";

export default async function ConnectPage() {
  const session = await auth.api.getSession({ headers: await headers() });
  return <ConnectClient signedIn={!!session} email={session?.user.email ?? null} />;
}
