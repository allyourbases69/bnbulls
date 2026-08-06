'use client';

/**
 * Top navigation — LAYOUT PORTED FROM FIGHTING FEFERS (`DECISIONS.md §33`).
 * Two-row on desktop:
 *   Row 1: [logo] [bnbulls (dead centre)] [wallet]
 *   Row 2: [mint] [duel] [the butcher] [marketplace] [pots] [browse]
 *          [how to play] [buy $BNBULL]
 *
 * Mobile (below md): single 64px row with logo + brand + wallet + hamburger;
 * the nav items collapse into a slide-down panel that closes on route change,
 * outside click, or item tap.
 *
 * ⚠ THE SIDE COLUMNS ARE BOTH `1fr` ON PURPOSE. With `auto_1fr_auto` the brand
 * centres inside the leftover space, and since the right column (wallet) is far
 * wider than the logo, the brand lands visibly left of the navbar's real
 * centre. Equal side columns make the middle column's centre the page's centre
 * whatever the sides contain. Fefers fixed this once; do not un-fix it.
 *
 * ⚠ `z-[60]` beats the mobile drop panel's `z-50`. Between `sm` and `md` BOTH
 * the header's connect button and the hamburger are on screen, and with equal
 * z-indexes the (later-in-DOM) panel painted over the connect button's
 * dropdown. They never overlap geometrically, so raising it is free.
 *
 * Every label comes from `lib/brand.ts`. No lore word is typed in this file.
 */
import Link from 'next/link';
import Image from 'next/image';
import { usePathname } from 'next/navigation';
import { useEffect, useState } from 'react';
import { ConnectButton } from './ConnectButton';
import { NAV, SITE_NAME, type NavEntry } from '@/lib/brand';
import { Wordmark } from '@/components/Wordmark';

export function NavBar() {
  const pathname = usePathname();
  const [open, setOpen] = useState(false);

  useEffect(() => {
    setOpen(false);
  }, [pathname]);

  useEffect(() => {
    if (!open) return undefined;
    document.body.style.overflow = 'hidden';
    return () => {
      document.body.style.overflow = '';
    };
  }, [open]);

  return (
    <>
      <nav className="sticky top-0 z-[60] border-b border-bull-border bg-bull-bg/95 backdrop-blur">
        <div className="mx-auto grid h-16 max-w-7xl grid-cols-[1fr_auto_1fr] items-center gap-3 px-4 md:px-8">
          {/* Left: Lord Wagyu, the mark (DECISIONS.md §34). py-1 is hit area
              only — on a phone the logo and the brand text are the only way
              back home, and both sit in a 64px items-center row, so nothing
              moves. */}
          <Link
            href="/"
            className="flex items-center justify-self-start py-1 transition-opacity hover:opacity-80"
            aria-label={`${SITE_NAME} home`}
          >
            <Image
              src="/lord-wagyu-head.png"
              alt=""
              width={44}
              height={44}
              priority
              unoptimized
              className="pixel h-9 w-9 rounded-full border border-bull-border md:h-11 md:w-11"
            />
          </Link>

          {/* Centre: brand, pinned dead-centre by the grid. */}
          <Link
            href="/"
            className="bull-header whitespace-nowrap py-3 text-center text-sm text-bull-text transition-colors hover:text-bull-gold md:py-0 md:text-xl"
          >
            <Wordmark />
          </Link>

          {/* Right: wallet + mobile hamburger. */}
          <div className="flex items-center gap-2 justify-self-end">
            <div className="hidden sm:block">
              <ConnectButton />
            </div>
            <button
              type="button"
              className="flex h-11 w-11 items-center justify-center border-2 border-bull-border text-bull-text transition-colors hover:border-bull-gold md:hidden"
              aria-label={open ? 'close menu' : 'open menu'}
              aria-expanded={open}
              onClick={() => setOpen((v) => !v)}
            >
              <span className="bull-header text-xl leading-none">{open ? '✕' : '☰'}</span>
            </button>
          </div>
        </div>

        {/* Row 2: nav items, desktop only, centred under the brand. The gap
            tightens at md so the row still fits a small laptop without
            spilling. */}
        <div className="hidden border-t border-bull-border/60 md:block">
          <div className="mx-auto flex h-12 max-w-7xl items-center justify-center gap-4 px-4 md:px-8 lg:gap-6">
            {NAV.map((item) => (
              <DesktopNavLink key={item.href} item={item} pathname={pathname} />
            ))}
          </div>
        </div>
      </nav>

      {open && (
        <>
          <div
            className="fixed inset-0 top-16 z-40 bg-black/60 backdrop-blur-sm md:hidden"
            onClick={() => setOpen(false)}
            aria-hidden
          />
          <div className="fixed left-0 right-0 top-16 z-50 border-b-2 border-bull-border bg-bull-bg shadow-2xl md:hidden">
            <div className="flex items-center justify-end border-b border-bull-border p-3 sm:hidden">
              <ConnectButton />
            </div>
            <div className="flex flex-col">
              {NAV.map((item) => {
                const isActive = !item.external && pathname === item.href;
                const className =
                  'bull-header border-b border-bull-border px-5 py-4 text-base transition-colors ' +
                  (item.cta
                    ? 'bull-bazinga-text hover:bg-bull-panel'
                    : isActive
                      ? 'bg-bull-panel text-bull-gold'
                      : 'text-bull-text hover:bg-bull-panel hover:text-bull-gold');
                if (item.external) {
                  return (
                    <a
                      key={item.href}
                      href={item.href}
                      target="_blank"
                      rel="noreferrer noopener"
                      className={className}
                    >
                      {item.label}
                    </a>
                  );
                }
                return (
                  <Link key={item.href} href={item.href} className={className}>
                    {item.label}
                  </Link>
                );
              })}
            </div>
          </div>
        </>
      )}
    </>
  );
}

function DesktopNavLink({ item, pathname }: { item: NavEntry; pathname: string }) {
  const isActive = !item.external && pathname === item.href;
  const className = item.cta
    ? 'bull-header text-sm whitespace-nowrap transition-colors bull-bazinga-text'
    : 'bull-header text-sm whitespace-nowrap transition-colors ' +
      (isActive ? 'text-bull-gold' : 'text-bull-text hover:text-bull-gold');
  if (item.external) {
    return (
      <a href={item.href} target="_blank" rel="noreferrer noopener" className={className}>
        {item.label}
      </a>
    );
  }
  return (
    <Link href={item.href} className={className}>
      {item.label}
    </Link>
  );
}
