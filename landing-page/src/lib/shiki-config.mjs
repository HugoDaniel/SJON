// Shiki configuration shared between Astro's markdown pipeline and the
// runtime highlight() helper used by static .astro snippets. Defining it
// once here keeps the markdown blocks and the hand-rolled snippets
// visually identical, and means a theme swap is a one-file change.

export const shikiThemes = {
  light: 'min-light',
  dark: 'min-dark',
};

// Strip Shiki's hardcoded background-color from the wrapping <pre> so the
// surrounding card surface (cream paper in light, ink in dark) shows
// through instead of a clashing slab of white/black. Per-token colours
// stay on the inner <span>s.
export const shikiTransformers = [
  {
    pre(node) {
      if (!node.properties || !node.properties.style) return;
      const style = String(node.properties.style)
        .split(';')
        .map((d) => d.trim())
        .filter((d) => d && !d.startsWith('background-color'))
        .join(';');
      if (style) node.properties.style = style;
      else delete node.properties.style;
    },
  },
];
