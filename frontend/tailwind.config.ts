import type { Config } from 'tailwindcss';

/**
 * ⚠ THERE ARE NO COLOUR VALUES IN THIS FILE, ON PURPOSE.
 *
 * Every one of them is a CSS custom property declared once on `:root` in
 * `src/app/globals.css`. `DECISIONS.md §17` says the look is not settled, so a
 * later change has to be a reskin and not a rebuild: one `:root` block for the
 * palette, `src/lib/brand.ts` for the lore strings, and nothing hardcoded
 * across twenty components.
 *
 * The `rgb(var(--x) / <alpha-value>)` form is what keeps Tailwind's opacity
 * modifiers alive — `text-bull-gold/40`, `border-bull-border/60` and the ~60
 * existing call sites like them all still work. A bare `var(--x)` holding a hex
 * string would silently break every one of them.
 */
const c = (name: string) => `rgb(var(--${name}) / <alpha-value>)`;

const config: Config = {
  content: ['./src/**/*.{js,ts,jsx,tsx,mdx}'],
  theme: {
    extend: {
      colors: {
        'bull-bg': c('bull-bg'),
        'bull-panel': c('bull-panel'),
        'bull-panel-hover': c('bull-panel-hover'),
        'bull-border': c('bull-border'),

        'bull-text': c('bull-text'),
        'bull-text-dim': c('bull-text-dim'),
        'bull-text-faint': c('bull-text-faint'),

        'bull-gold': c('bull-gold'),
        'bull-gold-hover': c('bull-gold-hover'),
        'bull-gold-hot': c('bull-gold-hot'),
        'bull-gold-ink': c('bull-gold-ink'),
        'bull-blood': c('bull-blood'),
        'bull-red': c('bull-red'),

        'rarity-common': c('rarity-common'),
        'rarity-uncommon': c('rarity-uncommon'),
        'rarity-rare': c('rarity-rare'),
        'rarity-epic': c('rarity-epic'),
        'rarity-legendary': c('rarity-legendary'),
      },
      fontFamily: {
        // Space Grotesk = display, DM Sans = body/UI, JetBrains Mono = data
        // (addresses, stats, ELO). Same three-font system as fighting fefers.
        display: ['"Space Grotesk"', 'ui-sans-serif', 'system-ui', 'sans-serif'],
        sans: ['"DM Sans"', 'ui-sans-serif', 'system-ui', 'sans-serif'],
        mono: [
          '"JetBrains Mono"',
          'ui-monospace',
          '"Cascadia Code"',
          '"SF Mono"',
          'Consolas',
          '"Liberation Mono"',
          'monospace',
        ],
      },
      keyframes: {
        'gold-pulse': {
          '0%, 100%': { boxShadow: '0 0 0 0 rgb(var(--bull-gold) / 0.35)' },
          '50%': { boxShadow: '0 0 0 8px rgb(var(--bull-gold) / 0)' },
        },
      },
      animation: {
        'gold-pulse': 'gold-pulse 1.5s ease-in-out infinite',
      },
    },
  },
  plugins: [],
};

export default config;
