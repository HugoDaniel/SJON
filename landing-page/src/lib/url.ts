// Build a URL that respects Astro's `base:` config. Internal hrefs and
// asset srcs in templates should run through this so the same source
// works whether the site is hosted at `/` or `/pages/sjon`.
//
// `import.meta.env.BASE_URL` is always normalized by Vite to end with a
// slash (`'/'` when no base is set, `'/pages/sjon/'` otherwise). We
// keep two forms: the raw value for the home link, and a slash-trimmed
// form for joining to `/`-rooted paths.

const RAW_BASE: string = import.meta.env.BASE_URL ?? '/';
const BASE_NO_SLASH = RAW_BASE.replace(/\/+$/, '');

const EXTERNAL_OR_ANCHOR = /^[a-z][a-z0-9+.-]*:|^\/\/|^#/i;

export function path(p: string): string {
  if (!p) return p;
  if (EXTERNAL_OR_ANCHOR.test(p)) return p;
  if (p === '/') return RAW_BASE;
  if (p.startsWith('/')) return BASE_NO_SLASH + p;
  return RAW_BASE + p;
}

export const BASE_PATH = BASE_NO_SLASH;
