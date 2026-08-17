import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Railway builds set NODE_ENV=production; nothing custom needed yet.
  reactStrictMode: true,
};

export default nextConfig;
