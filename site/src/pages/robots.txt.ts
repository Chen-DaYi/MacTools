const sitemapURL = new URL("/sitemap.xml", import.meta.env.SITE).href;

export function GET() {
  return new Response(`User-agent: *\nAllow: /\n\nSitemap: ${sitemapURL}\n`, {
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
    },
  });
}
