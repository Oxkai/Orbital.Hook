import type { NextConfig } from "next";

const securityHeaders = [
  // Prevent clickjacking
  { key: "X-Frame-Options",        value: "DENY" },
  // Stop MIME-type sniffing
  { key: "X-Content-Type-Options", value: "nosniff" },
  // Don't send referrer to external origins
  { key: "Referrer-Policy",        value: "strict-origin-when-cross-origin" },
  // Disable interest-cohort tracking
  { key: "Permissions-Policy",     value: "interest-cohort=()" },
  // CSP: wallet extensions need unsafe-inline/unsafe-eval for injected scripts;
  // connect-src https: covers any RPC endpoint without locking to a specific URL
  {
    key: "Content-Security-Policy",
    value: [
      "default-src 'self'",
      "connect-src 'self' https:",
      "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
      "font-src 'self' https://fonts.gstatic.com",
      "script-src 'self' 'unsafe-inline' 'unsafe-eval'",
      "img-src 'self' data: https:",
      "frame-ancestors 'none'",
    ].join("; "),
  },
];

const nextConfig: NextConfig = {
  // Pin Turbopack's workspace root to this directory.
  //
  // Next infers the root by looking for lockfiles, and the repo now holds two
  // (`frontend/package-lock.json` and `subgraph/package-lock.json`). When that
  // inference picks a directory with no `node_modules`, Turbopack cannot
  // resolve the framework itself and dev dies with "Next.js package not found"
  // while still serving 200s, which is a genuinely confusing failure. Pinning
  // it removes the ambiguity rather than relying on which lockfile wins.
  turbopack: {
    root: __dirname,
  },

  async headers() {
    return [
      {
        source: "/(.*)",
        headers: securityHeaders,
      },
    ];
  },
};

export default nextConfig;
