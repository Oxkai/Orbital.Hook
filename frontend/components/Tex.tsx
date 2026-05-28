import katex from "katex";

/// Renders a LaTeX string with KaTeX. Server-safe (renders to an HTML string).
/// `block` switches to display mode (centered, larger).
export function Tex({ children, block = false }: { children: string; block?: boolean }) {
  const html = katex.renderToString(children, {
    throwOnError: false,
    displayMode: block,
    output: "html",
  });
  return (
    <span
      className={block ? "block" : "inline-block"}
      style={{ color: "inherit" }}
      dangerouslySetInnerHTML={{ __html: html }}
    />
  );
}
