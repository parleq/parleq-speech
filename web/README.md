# Parleq website

Marketing site for [Parleq](https://github.com/parleq/parleq-speech) — built with [Astro](https://astro.build/) + Tailwind CSS v4, deployed to GitHub Pages by `.github/workflows/deploy-pages.yml` on every push to `main` that touches `web/`.

Live at: <https://parleq.app>

## Develop

```bash
cd web
npm install     # one-time
npm run dev     # http://localhost:4321
```

The dev server hot-reloads on every save. Hit **q** + **enter** to quit.

### GitHub API auth (latest-release fetch)

The landing page fetches the latest release at build time so the download button links directly at the latest `.dmg`. Token resolution falls through, in order:

1. `GITHUB_TOKEN` env — set automatically in the deploy-pages workflow.
2. `GH_TOKEN` env — alternate convention.
3. `gh auth token` — picks up your local `gh` CLI session, no env needed.
4. Unauthenticated — works once the repo is public; while it's private, the API returns 404 and the build falls back to the generic Releases-page URL (the page still renders, just without the version pinned).

So local `npm run build` should "just work" if you've signed into the `gh` CLI.

## Build + preview

```bash
npm run build   # writes web/dist/
npm run preview # serves the built bundle locally for a final eye-check
```

## Where things live

```
web/
├── astro.config.mjs       site URL + vite plugins
├── package.json
├── public/                static assets copied 1:1 to /
│   ├── favicon.svg
│   └── CNAME              parleq.app — GitHub Pages custom-domain handshake
└── src/
    ├── layouts/Layout.astro    HTML shell, fonts, OG meta
    ├── pages/index.astro       landing page
    ├── pages/how-it-works.astro
    ├── pages/about.astro
    ├── pages/faq.astro
    └── pages/docs/             provider setup guides
```

Pages get URLs from filename: `src/pages/foo.astro` → `/foo/`.

## Design tokens

Custom theme defined in `src/styles/global.css` under `@theme { … }`:

- **Fonts**: Fraunces (variable serif, optical sizing) for display, Inter for body, JetBrains Mono for code.
- **Palette**: warm white background (`#fafaf7`), slate text, amber accent (`#d97706`). Distinct from typical Tailwind-defaulted developer-tool sites.
- **Sound-bar motif**: same accent color as the in-app `SoundWaveBars` view — keeps the website continuous with the product.

To tweak the look-and-feel, edit those tokens in one place rather than chasing arbitrary classes through `index.astro`.

## Custom domain

The site is served at `parleq.app` via GitHub Pages. The handshake:

1. **`web/public/CNAME`** contains `parleq.app`. Astro copies it to `dist/CNAME`, the deploy workflow uploads it as part of the Pages artifact, and GitHub Pages reads it on the deployed site to know which custom domain to honor.
2. **GitHub Pages settings** → repo → Settings → Pages → Custom domain set to `parleq.app`.
3. **DNS** — `parleq.app` and `www.parleq.app` need to point at GitHub Pages per [GitHub's docs](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site).

Once those three are set, every push to `main` that touches `web/` redeploys to `parleq.app`.
