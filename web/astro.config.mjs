// Astro config for the Parleq marketing site. Deployed at
// https://parleq.app via GitHub Pages with a custom-domain
// handshake (web/public/CNAME → published as /CNAME on the
// gh-pages site → GitHub honors as the custom domain).
//
// Note: removing `base` (was "/parleq-speech") means all internal
// links resolve at the root path. Every .astro page already builds
// hrefs through `import.meta.env.BASE_URL`, so the transition is
// transparent — BASE_URL becomes "/" on the new domain.

import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  site: 'https://parleq.app',
  // `site` above is what makes the sitemap URLs absolute.
  integrations: [sitemap()],
  vite: {
    plugins: [tailwindcss()],
  },
});
