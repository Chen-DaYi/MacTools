# MacTools Site

Astro source for the MacTools project website.

## Structure

- `src/pages/`: file-based routes. The homepage lives at `src/pages/index.astro`.
- `src/layouts/`: page shells and shared metadata.
- `src/components/`: reusable page sections and UI fragments.
- `src/styles/`: global styles and design tokens.
- `src/scripts/`: small client-side enhancements.
- `public/`: static assets copied into the built site unchanged.

The GitHub Pages workflow builds this package, then merges the output with the repository `docs/` directory so existing release files such as `appcast.xml`, plugin catalogs, and icon gallery assets keep their public URLs.

## Commands

```bash
cd site
npm install
npm run dev
npm run build
```
