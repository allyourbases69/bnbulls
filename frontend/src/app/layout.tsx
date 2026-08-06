import type { Metadata } from 'next';
import { Providers } from './providers';
import { NavBar } from '@/components/NavBar';
import { PotTicker } from '@/components/PotTicker';
import { SiteFooter } from '@/components/SiteFooter';
import { siteUrl } from '@/lib/env';
import { DESCRIPTION, SITE_NAME, TAGLINE } from '@/lib/brand';
import './globals.css';

const TITLE = `${SITE_NAME}: ${TAGLINE}`;

export const metadata: Metadata = {
  metadataBase: new URL(siteUrl()),
  title: {
    default: TITLE,
    template: `%s | ${SITE_NAME}`,
  },
  description: DESCRIPTION,
  /*
   * ⚠ NO `icons` OR `openGraph.images` OVERRIDE HERE, DELIBERATELY.
   *
   * They come from the app-router FILE convention instead:
   *   src/app/icon.png            → the browser tab icon
   *   src/app/apple-icon.png      → apple-touch-icon / home-screen icon
   *   src/app/opengraph-image.png → telegram + facebook link previews
   *   src/app/twitter-image.png   → X link previews
   *
   * All four are LORD WAGYU (`DECISIONS.md §34`), and all four are generated
   * from the live art engine by `npm run gen:brand` — never hand-drawn, so
   * they can never drift from the bull the chain describes. Adding an `icons`
   * key here would silently outrank the files and is how fefers' hero went
   * stale once already.
   */
  openGraph: {
    title: TITLE,
    description: DESCRIPTION,
    url: siteUrl(),
    siteName: SITE_NAME,
    type: 'website',
  },
  twitter: {
    card: 'summary_large_image',
    title: TITLE,
    description: DESCRIPTION,
  },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <head>
        {/*
          Google Fonts preload. Space Grotesk = display, DM Sans = body/UI,
          JetBrains Mono = data (addresses, stats, ELO). preconnect on both
          the google host and gstatic cuts ~200ms off first paint; @import in
          CSS would cost a FOUT instead.
        */}
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="" />
        {/*
          eslint's `no-page-custom-font` is a PAGES-ROUTER heuristic: it warns
          that a font linked from a component only loads for that one page.
          This is the app router's ROOT layout, so the tag is on every page by
          construction and the warning does not apply.

          `next/font/google` is the other option and is deliberately not used:
          it fetches the font files at BUILD time, which would make a deploy of
          a live site fail whenever Google is having a bad day. A stylesheet
          link degrades to the system fallback instead. Same call fefers made.
        */}
        {/* eslint-disable-next-line @next/next/no-page-custom-font */}
        <link
          href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@500;700&family=DM+Sans:wght@400;500;700&family=JetBrains+Mono:wght@400;500;700&display=swap"
          rel="stylesheet"
        />
      </head>
      <body className="bull-app-texture">
        <Providers>
          <NavBar />
          {/* Site-wide pot strip: the pots stay in view on every page,
              growing. Renders nothing at all when no pot is deployed. */}
          <PotTicker />
          <main className="relative z-10 min-h-[calc(100vh-4rem)] md:min-h-[calc(100vh-7rem)]">
            {children}
          </main>
          <SiteFooter />
        </Providers>
      </body>
    </html>
  );
}
