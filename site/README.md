# MacTools Site

Astro source for the MacTools project website.

## Structure

- `src/pages/`: file-based routes. The homepage lives at `src/pages/index.astro`.
- `src/layouts/`: page shells and shared metadata.
- `src/components/`: reusable page sections and UI fragments.
- `src/styles/`: global styles and design tokens.
- `src/scripts/`: small client-side enhancements.
- `public/`: static assets copied into the built site unchanged.

The About route presents the existing bilingual project story as a skippable cinematic crawl, then switches to a conventional reading layout when the animation finishes.

The Plugins route mirrors the native MacTools settings window with a searchable marketplace, horizontal category filters, responsive navigation, and interactive previews for plugin-specific settings.

The GitHub Pages workflow builds this package, then merges the output with the repository `docs/` directory so existing release files such as `appcast.xml`, plugin catalogs, and icon gallery assets keep their public URLs.

## Commands

```bash
cd site
npm install
npm run dev
npm run build
```
