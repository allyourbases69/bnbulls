'use client';

import { useReadContract } from 'wagmi';
import { DuelAbi } from '@/lib/abi';
import { CHAIN_ID } from '@/lib/env';
import { QUOTE_REFRESH_MS } from '@/lib/constants';

/**
 * WHAT ONE BNB IS WORTH, LIVE, FOR PUTTING A DOLLAR BESIDE A BNB FIGURE.
 *
 * ⚠ WHY THIS EXISTS AT ALL. The bull pit prices a fight as a dollar sticker and
 * converts it through Chainlink at pay time, so every BNB amount on the page is
 * a moving number derived from a rate nobody on the client can see. A player
 * being asked to send 0.0332 BNB has no idea whether that is lunch money or a
 * week's rent unless the page says so — and "is that a lot" is the question
 * underneath the owner's complaint that the pit never quotes what it is about to
 * take.
 *
 * ⚠ THE SAME ANSWER THE CONTRACT USES, NOT A SECOND OPINION. `Duel.bnbUsdPrice`
 * forwards to `MintDrop.bnbUsdPrice()`, which is the one Chainlink read every
 * price in this app already converts through. Pulling a rate from an exchange
 * api instead would let the dollars on screen disagree with the BNB beside them
 * whenever the two sources drifted, and the BNB is the number that gets signed.
 *
 * ⚠ A REVERT IS AN ANSWER, AND IT MUST STAY `undefined`. The oracle read reverts
 * on a stale round, a non-positive answer, or a price outside its sanity band —
 * deliberately, because `stickerCost` refuses to quote a BNB fight off a sick
 * feed. wagmi surfaces that as no data, so every caller renders a dash and the
 * BNB figure stands alone. Filling the gap with a cached or guessed rate would
 * attach a confident dollar sign to money about to move, which is worse than
 * saying nothing.
 *
 * ⚠ NEVER USE THIS TO DERIVE AN AMOUNT TO SEND. It is for the words beside the
 * number, never the number. Everything a wallet is asked to sign for comes off
 * `fighterCost` / `stickerCost`, which do the conversion on chain — two
 * implementations of one formula always drift, and this one rounds for humans.
 */
export function useBnbUsdPrice(duel: `0x${string}` | undefined): bigint | undefined {
  const { data } = useReadContract({
    address: duel,
    abi: DuelAbi,
    functionName: 'bnbUsdPrice',
    chainId: CHAIN_ID,
    query: {
      enabled: !!duel,
      refetchInterval: QUOTE_REFRESH_MS,
      // One bad round must not blank the dollars for the rest of the session,
      // and it must not hammer a feed that is genuinely down either.
      retry: 1,
    },
  });
  const price = data as bigint | undefined;
  return price !== undefined && price > 0n ? price : undefined;
}
