import { defineCollection } from 'astro:content';
import { glob } from 'astro/loaders';
// Astro 7 deprecates re-exporting `z` from `astro:content`; import it from
// `astro/zod` (zod v4) instead.
import { z } from 'astro/zod';

// Tutorial lessons. Lessons are the only entries we render — meta files
// are gone now that TutorialKit is no longer the renderer; the part /
// chapter grouping lives in src/lib/lessons.ts instead.
//
// Each lesson is a `content.md` under a part/chapter/lesson directory, so
// the loader ids come out as `<lesson.dir>/content` — the shape
// src/pages/[...slug].astro matches against.
const tutorial = defineCollection({
  loader: glob({ base: './src/content/tutorial', pattern: '**/content.md' }),
  schema: z.object({
    type: z.literal('lesson').default('lesson'),
    title: z.string(),
  }),
});

export const collections = { tutorial };
