import { ImageResponse } from "next/og";
import { readFileSync } from "node:fs";
import { join } from "node:path";

export const size = { width: 180, height: 180 };
export const contentType = "image/png";

const logo = `data:image/svg+xml;base64,${readFileSync(
  join(process.cwd(), "public", "logo.svg"),
).toString("base64")}`;

// iOS ignores transparency and composites onto white, so the mark ships on its
// own dark plate: the same treatment as app/icon.svg.
export default function AppleIcon() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          background: "#0A0A0A",
        }}
      >
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img src={logo} width={116} height={116} alt="" />
      </div>
    ),
    size,
  );
}
