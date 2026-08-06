/**
 * Site footer — layout ported from fighting fefers' `Footer` (`DECISIONS.md
 * §33`): a centred row of social glyphs, the token CA when there is one, the
 * brand tagline, then a thin link row.
 *
 * Inline SVG icons, no external icon dependency, so the bundle stays tiny.
 *
 * ⚠ ONLY CLAIMED DESTINATIONS GET PRINTED. An unclaimed handle in a footer is
 * a squat invitation, learned the hard way on fefers. The X and Telegram
 * handles here are the ones `DECISIONS.md §5` locked and embedded in every
 * contract we deploy. There is no GitHub link because the repo is not public.
 *
 * ⚠ THE CA ROW IS ENV-DRIVEN AND ABSENT UNTIL A REAL DEPLOY. `contractAddress`
 * returns null on an unset/malformed var rather than a placeholder, so a
 * plausible-looking fake address can never reach a page. `DECISIONS.md §29`
 * also means the token genuinely does not exist yet.
 */
import type { ReactElement } from 'react';
import { xUrl, telegramUrl, githubUrl, explorerBaseUrl, contractAddress } from '@/lib/env';
import { DESCRIPTION, SAFETY, TICKER } from '@/lib/brand';

interface SocialLink {
  href: string;
  label: string;
  icon: ReactElement;
}

const XIcon = (
  <svg viewBox="0 0 24 24" aria-hidden className="h-5 w-5" fill="currentColor">
    <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231 5.452-6.231Zm-1.161 17.52h1.833L7.084 4.126H5.117L17.083 19.77Z" />
  </svg>
);

const GitHubIcon = (
  <svg viewBox="0 0 24 24" width="20" height="20" fill="currentColor" aria-hidden="true">
    <path d="M12 .5a12 12 0 0 0-3.79 23.4c.6.1.82-.26.82-.58v-2.2c-3.34.72-4.04-1.6-4.04-1.6-.55-1.4-1.34-1.77-1.34-1.77-1.1-.75.08-.73.08-.73 1.2.08 1.84 1.24 1.84 1.24 1.07 1.84 2.81 1.3 3.5 1 .1-.78.42-1.31.76-1.61-2.67-.3-5.47-1.34-5.47-5.96 0-1.32.47-2.4 1.24-3.24-.13-.3-.54-1.53.12-3.18 0 0 1.01-.32 3.3 1.24a11.5 11.5 0 0 1 6.01 0c2.29-1.56 3.3-1.24 3.3-1.24.66 1.65.25 2.88.12 3.18.77.84 1.24 1.92 1.24 3.24 0 4.63-2.81 5.65-5.49 5.95.43.37.82 1.1.82 2.22v3.29c0 .32.21.69.82.57A12 12 0 0 0 12 .5Z" />
  </svg>
);

const TelegramIcon = (
  <svg viewBox="0 0 24 24" aria-hidden className="h-5 w-5" fill="currentColor">
    <path d="M11.944 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0a12 12 0 0 0-.056 0Zm4.962 7.224c.1-.002.321.023.465.14a.506.506 0 0 1 .171.325c.016.093.036.306.02.472-.18 1.898-.962 6.502-1.36 8.627-.168.9-.499 1.201-.82 1.23-.696.065-1.225-.46-1.9-.902-1.056-.693-1.653-1.124-2.678-1.8-1.185-.78-.417-1.21.258-1.91.177-.184 3.247-2.977 3.307-3.23.007-.032.014-.15-.056-.212s-.174-.041-.249-.024c-.106.024-1.793 1.14-5.061 3.345-.48.33-.913.49-1.302.48-.428-.008-1.252-.241-1.865-.44-.752-.245-1.349-.374-1.297-.789.027-.216.325-.437.893-.663 3.498-1.524 5.83-2.529 6.998-3.014 3.332-1.386 4.025-1.627 4.476-1.635z" />
  </svg>
);

export function SiteFooter() {
  const gh = githubUrl();
  const socials: SocialLink[] = [
    { href: xUrl(), label: 'x', icon: XIcon },
    { href: telegramUrl(), label: 'telegram', icon: TelegramIcon },
    // Only rendered when a URL is configured — see `githubUrl`. A dead link on
    // the "read the code" promise is worse than no link.
    ...(gh ? [{ href: gh, label: 'github', icon: GitHubIcon }] : []),
  ];
  const token = contractAddress('bnbullToken');
  const explorer = explorerBaseUrl();

  return (
    <footer className="mt-12 border-t border-bull-border bg-bull-bg/95">
      <div className="mx-auto flex max-w-7xl flex-col items-center gap-3 px-4 py-6 md:px-8">
        <ul className="flex items-center gap-5">
          {socials.map((s) => (
            <li key={s.label}>
              <a
                href={s.href}
                target="_blank"
                rel="noreferrer noopener"
                aria-label={s.label}
                /* py-3 is hit area only. The 20px glyph + label is unchanged,
                   it just clears Apple's 44px tap floor on a phone. */
                className="flex items-center gap-2 py-3 text-bull-text-dim transition-colors hover:text-bull-gold"
              >
                {s.icon}
                <span className="bull-header text-xs">{s.label}</span>
              </a>
            </li>
          ))}
        </ul>

        {token && (
          <div className="font-mono text-xs text-bull-text-faint">
            ${TICKER} CA:{' '}
            <a
              href={`${explorer}/token/${token}`}
              target="_blank"
              rel="noreferrer noopener"
              className="inline-block break-all py-1.5 text-bull-gold hover:underline md:py-0"
              title="view on the block explorer"
            >
              {token}
            </a>
          </div>
        )}

        <p className="bull-header max-w-2xl text-center text-[0.65rem] tracking-wider text-bull-text-faint">
          {DESCRIPTION}
        </p>

        {/* inline-block + padding gives these a real hit area on a phone. */}
        <p className="flex flex-wrap items-center justify-center text-xs text-bull-text-faint">
          <a
            href="/about"
            className="inline-block px-2 py-3.5 transition-colors hover:text-bull-gold"
          >
            how to play
          </a>
          <span aria-hidden>·</span>
          <a
            href="/pots"
            className="inline-block px-2 py-3.5 transition-colors hover:text-bull-gold"
          >
            the pots
          </a>
          <span aria-hidden>·</span>
          <a
            href={explorer}
            target="_blank"
            rel="noreferrer noopener"
            className="inline-block px-2 py-3.5 transition-colors hover:text-bull-gold"
          >
            block explorer
          </a>
        </p>

        <p className="max-w-2xl text-center text-[0.65rem] text-bull-text-faint">{SAFETY}</p>
      </div>
    </footer>
  );
}
