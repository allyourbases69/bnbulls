/**
 * Wordmark.tsx — the project name, set the one correct way.
 *
 * ⚠ THIS IS THE ONE PLACE THE NAME IS STYLED. Owner call, 2026-08-06:
 * "website should be BNBulls and the BNB should be gold as per BNB logo, make
 * it case sensitive like that."
 *
 * So: **BNB** in BNB Chain's own gold (`#F0B90B`, `--bull-gold`), then `ulls`
 * in the body colour. The capitalisation is deliberate and is the ONE
 * documented exception to `VOICE-AND-BRAND.md §1`'s lowercase rule — every
 * other heading, label and sentence on the site stays lowercase. A wordmark is
 * a mark, not a sentence.
 *
 * It used to render as `bn` + gold `bulls`, which split the name in the wrong
 * place: the chain is BNB, so the gold has to land on exactly those three
 * letters or the pun stops working.
 *
 * Do not inline this markup anywhere. If the brand shifts, it shifts here.
 */
export interface WordmarkProps {
  /** Extra classes for size/weight. Colour is owned by this component. */
  className?: string;
}

export function Wordmark({ className = '' }: WordmarkProps) {
  return (
    <span className={className}>
      {/* aria-hidden is wrong here: screen readers should read the whole
          name, and it is a single text node to them either way. */}
      <span className="text-bull-gold">BNB</span>ulls
    </span>
  );
}
