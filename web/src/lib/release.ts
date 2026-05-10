// Fetches the latest GitHub release at site-build time so the
// download button can link directly at the .dmg asset and display
// the version. Runs on the Node.js side during `astro build` —
// never executes in the browser.
//
// Token resolution, in order:
//   1. GITHUB_TOKEN env (set by the deploy-pages workflow secret)
//   2. GH_TOKEN env (alternate convention some CI systems use)
//   3. `gh auth token` shell-out (local dev with the gh CLI signed in)
//   4. unauthenticated (works fine once the repo is public; while
//      private, returns 404 and we fall back to the Releases-page URL)
//
// Failures fall back to a generic Releases-page URL so a hiccup in
// the GitHub API never breaks the deploy. In that case `version`
// is null and the call site renders a generic CTA.

import { execSync } from 'node:child_process';

const REPO = 'parleq/parleq-speech';
const FALLBACK_RELEASES_PAGE = `https://github.com/${REPO}/releases`;

function resolveToken(): string | undefined {
  if (process.env.GITHUB_TOKEN) return process.env.GITHUB_TOKEN;
  if (process.env.GH_TOKEN) return process.env.GH_TOKEN;
  try {
    return execSync('gh auth token', { stdio: ['pipe', 'pipe', 'ignore'] })
      .toString()
      .trim() || undefined;
  } catch {
    return undefined;
  }
}

export interface LatestRelease {
  /** Tag, e.g. "v0.5.0". null when the API call failed. */
  version: string | null;
  /** Direct .dmg download URL — or the Releases page URL as fallback. */
  downloadUrl: string;
  /** SHA-256 sidecar URL if present in the release assets. */
  sha256Url: string | null;
  /** Release-page URL on github.com — handy for "see all releases" links. */
  releasePageUrl: string;
}

export async function fetchLatestRelease(): Promise<LatestRelease> {
  const headers: Record<string, string> = {
    Accept: 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
  };
  const token = resolveToken();
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }

  try {
    const res = await fetch(
      `https://api.github.com/repos/${REPO}/releases/latest`,
      { headers }
    );
    if (!res.ok) {
      console.warn(`[release] GitHub API returned ${res.status}; using fallback`);
      return {
        version: null,
        downloadUrl: FALLBACK_RELEASES_PAGE,
        sha256Url: null,
        releasePageUrl: FALLBACK_RELEASES_PAGE,
      };
    }
    const data = await res.json() as {
      tag_name: string;
      html_url: string;
      assets: Array<{ name: string; browser_download_url: string }>;
    };
    const dmg = data.assets.find((a) => a.name.toLowerCase().endsWith('.dmg'));
    const sha = data.assets.find((a) => a.name.toLowerCase().endsWith('.dmg.sha256'));
    return {
      version: data.tag_name,
      downloadUrl: dmg?.browser_download_url ?? data.html_url,
      sha256Url: sha?.browser_download_url ?? null,
      releasePageUrl: data.html_url,
    };
  } catch (err) {
    console.warn('[release] failed to fetch latest release; using fallback:', err);
    return {
      version: null,
      downloadUrl: FALLBACK_RELEASES_PAGE,
      sha256Url: null,
      releasePageUrl: FALLBACK_RELEASES_PAGE,
    };
  }
}
