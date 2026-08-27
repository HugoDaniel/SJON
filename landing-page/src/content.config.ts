import { defineCollection } from 'astro:content';
import { docsSchema } from '@astrojs/starlight/schema';
import { sjonDocsLoader } from './lib/docs-loader.ts';

// One collection, four sources. `sjonDocsLoader` composes Starlight's own
// file-backed loader with the tutorial sources and the generated diagnostic
// catalogue; see its header for why that composition lives in a loader rather
// than here.
export const collections = {
  docs: defineCollection({ loader: sjonDocsLoader(), schema: docsSchema() }),
};
