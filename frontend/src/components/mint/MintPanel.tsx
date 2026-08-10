'use client';

import { useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import { parseEventLogs } from 'viem';
import { useQueryClient } from '@tanstack/react-query';
import { useAccount, useBalance, useReadContract, useReadContracts, useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { BullsAbi, MintDropAbi } from '@/lib/abi';
import { contractAddress, CHAIN_ID, explorerBaseUrl } from '@/lib/env';
import { formatUsd1e18, formatToken, formatBps } from '@/lib/format';
import { useTokenDecimals, NATIVE_BNB_DECIMALS } from '@/lib/hooks/useTokenDecimals';
import { useErc20Approval } from '@/lib/hooks/useErc20Approval';
import { useWrongNetwork } from '@/lib/hooks/useWrongNetwork';
import { NotDeployed } from '@/components/shared/NotDeployed';
import { WrongNetworkNotice } from '@/components/shared/WrongNetwork';
import { BullCard, BullCardLink, type BullFacts } from '@/components/bulls/BullCard';
import { isValidBullId } from '@/lib/art/collection';
import { withCushion, QUOTE_REFRESH_MS, MINT_GAS_HEADROOM_WEI } from '@/lib/constants';
import { CURRENCY, PEN, PIT } from '@/lib/brand';
import { usePreflight } from '@/lib/hooks/usePreflight';
import { RevertNotice } from '@/components/shared/RevertNotice';
import { decodeRevert, type DecodedRevert } from '@/lib/revertDecode';
import { KING_ID, SUPPLY } from '@/lib/art/bull';
import { useMintedBulls } from '@/lib/hooks/useMintedBulls';
import { usePen, usePenWrites, useReservation, type ReservationView } from '@/lib/hooks/usePen';
import {
  PendingReservations,
  RefundedDialogue,
  ReservationRow,
} from '@/components/mint/PendingReservations';

const STATIC_LADDER = [
  { upToSold: 100, usd: 10 },
  { upToSold: 200, usd: 20 },
  { upToSold: 300, usd: 35 },
  { upToSold: 400, usd: 50 },
  { upToSold: 500, usd: 75 },
];

/**
 * ⚠ TWO CURRENCIES (`DECISIONS.md §26`). The stablecoin leg is gone from the
 * contract, so `mintWithStable` no longer exists, `wires()` no longer returns
 * a stablecoin address, and `quote()` returns FOUR values instead of five.
 * Reading the old 5-tuple silently shifted every column by one and would have
 * shown the BNBULL amount where the BNB amount belongs.
 */
type PayAsset = 'bnb' | 'bnbull';

/**
 * The mint's own progress, one step at a time. See `mintPhase` below.
 *
 * ⚠ `drawing` EXISTS ONLY ON THE PEN PATH, AND IT IS A REAL PHASE RATHER THAN A
 * LONGER "mining". Under `BullPen` the buyer's transaction pays and reserves;
 * it does not mint anything and it does not know which bulls they get. The ids
 * are drawn in a SECOND transaction, from a seed that did not exist when they
 * paid — which is the entire anti-snipe design (see `PEN` in `brand.ts`).
 * Folding that into "mining" would tell a buyer their transaction had not
 * landed when it had, and hide the one screen where they might have a button to
 * press.
 */
type MintPhase =
  | 'idle'
  | 'signing'
  | 'mining'
  | 'reverted'
  | 'drawing'
  /**
   * ⚠ A TERMINAL OUTCOME, AND NOT THE SAME THING AS `reverted`. A reverted mint
   * never happened: nothing was charged beyond gas and the buyer can simply try
   * again. A refunded one DID happen, took real money, held it for hours, and
   * gave it back because the draw never landed. Collapsing the two would tell
   * somebody whose payment sat in escrow all afternoon that their transaction
   * "failed", which is both wrong and the single most alarming way to be wrong.
   */
  | 'refunded'
  | 'revealing'
  | 'success';

/** `Bulls.getBull` — only the fields the reveal shows. */
interface ChainBull {
  readonly strength: number;
  readonly dexterity: number;
  readonly constitution: number;
  readonly intelligence: number;
  readonly wisdom: number;
  readonly charisma: number;
  readonly elo: number;
  readonly wins: number;
  readonly losses: number;
  readonly ties: number;
  readonly isDead: boolean;
  readonly name: string;
}

/** `Bulls.getBullWeapon`. */
interface ChainWeapon {
  readonly name: string;
  readonly damageMin: number;
  readonly damageMax: number;
  readonly speed: number;
}

interface MintedBull {
  readonly id: number;
  readonly bull?: ChainBull;
  readonly weapon?: ChainWeapon;
}

export function MintPanel() {
  const mintDropAddress = contractAddress('mintDrop');
  const bullsAddress = contractAddress('bullsNft');
  const { address: account } = useAccount();
  const queryClient = useQueryClient();
  const [count, setCount] = useState(1);
  const [asset, setAsset] = useState<PayAsset>('bnb');

  const { wrongNetwork } = useWrongNetwork();

  const {
    data: totalSold,
    isLoading: loadingSold,
    refetch: refetchSold,
  } = useReadContract({
    address: mintDropAddress ?? undefined,
    abi: MintDropAbi,
    functionName: 'totalSold',
    query: { enabled: !!mintDropAddress, refetchInterval: 15_000 },
  });
  const {
    data: maxMint,
    isLoading: loadingMax,
    refetch: refetchMax,
  } = useReadContract({
    address: mintDropAddress ?? undefined,
    abi: MintDropAbi,
    functionName: 'MAX_MINT',
    query: { enabled: !!mintDropAddress },
  });
  /**
   * ⚠ THE DROP SHIPS PAUSED, AND WITHOUT THIS READ THE PAGE LIES ABOUT IT.
   *
   * `MintDrop`'s constructor calls `_pause()` and `unpause()` is the deliberate
   * "start minting" switch (`contracts/MintDrop.sol`, and `mintWithBNB` /
   * `mintWithBNBULL` both carry `whenNotPaused`). So between deploy and go-live
   * the honest state of this page is "not open yet". Without the read it offers
   * a live mint button that reverts on every single click, which reads as a
   * broken site on the one day the site is being watched hardest.
   */
  const {
    data: isPaused,
    isLoading: loadingPaused,
    refetch: refetchPaused,
  } = useReadContract({
    address: mintDropAddress ?? undefined,
    abi: MintDropAbi,
    functionName: 'paused',
    query: { enabled: !!mintDropAddress, refetchInterval: 15_000 },
  });
  const { data: tierCount } = useReadContract({
    address: mintDropAddress ?? undefined,
    abi: MintDropAbi,
    functionName: 'priceTierCount',
    query: { enabled: !!mintDropAddress },
  });
  const { data: bnbullAddress } = useReadContract({
    address: mintDropAddress ?? undefined,
    abi: MintDropAbi,
    functionName: 'bnbull',
    query: { enabled: !!mintDropAddress },
  });

  const tierIndices = useMemo(
    () => Array.from({ length: tierCount ? Number(tierCount) : 0 }, (_, i) => i),
    [tierCount],
  );
  const { data: tierRows } = useReadContracts({
    contracts: tierIndices.map((i) => ({
      address: mintDropAddress ?? undefined,
      abi: MintDropAbi,
      functionName: 'priceTierAt' as const,
      args: [BigInt(i)] as const,
    })),
    query: { enabled: !!mintDropAddress && tierIndices.length > 0 },
  });

  /**
   * ⚠ A FAILED READ IS NOT A SOLD-OUT DROP, AND IT USED TO RENDER AS ONE.
   *
   * `supply` defaulted to 0 when the `MAX_MINT` read came back undefined, which
   * made `remaining` 0, which rendered "the drop is sold out." — permanently,
   * because once react-query stops retrying `isLoading` goes false and nothing
   * ever revisits it. One flaky RPC on launch day and every visitor is told the
   * drop is gone. These three states are now distinct and only one of them is
   * allowed to make that claim:
   *
   *   loading      → the reads are still in flight, say nothing
   *   unavailable  → they settled with no answer, say THAT and offer a retry
   *   sold out     → `MAX_MINT` was actually read and `totalSold` reached it
   *
   * `paused` is folded into the same bucket for the same reason: an unread
   * pause flag must not be reported as either open or closed.
   */
  const dropStateLoading = loadingSold || loadingMax || loadingPaused;
  const dropStateUnavailable =
    !dropStateLoading &&
    (totalSold === undefined || maxMint === undefined || isPaused === undefined);
  const dropStateKnown = !dropStateLoading && !dropStateUnavailable;

  /**
   * ⚠ `totalSold` IS THE TIER LADDER'S NUMBER AND NOTHING ELSE. DO NOT REUSE IT
   * FOR THE HEADLINE COUNT.
   *
   * `MintDrop.totalSold` counts what THIS drop contract has sold. That is
   * exactly right for pricing — the ladder is defined against it and steps on
   * it, so `tierStatus` below must keep reading it — and it is wrong for
   * "N / 500 minted" the moment a SECOND drop is deployed, which is what the
   * pen migration does. The new drop restarts at 0 while several dozen bulls
   * are already out in the world, so a headline off `totalSold` would tell a
   * visitor the collection had barely started when it had not.
   */
  const sold = totalSold !== undefined ? Number(totalSold) : 0;
  const supply = maxMint !== undefined ? Number(maxMint) : 0;

  const pen = usePen();
  const herd = useMintedBulls();

  /**
   * HOW MANY OF THE 500 ARE IN CIRCULATION — the honest headline number.
   *
   * ⚠ THE KING IS EXCLUDED, AND HE ALWAYS HAS BEEN. #501 sits outside
   * `MAX_SUPPLY` and is minted by his own function, never sold through the drop,
   * so `totalSold` never counted him and neither does this. Counting him would
   * make a completed drop read "501 / 500".
   */
  const circulating = useMemo(
    () => herd.ids.filter((id) => id !== KING_ID).length,
    [herd.ids],
  );

  /**
   * THE THREE NUMBERS ON THE HEADER, DEFINED ONCE.
   *
   * ⚠ `headlineLeft` IS `poolSize()` UNDER THE PEN — what is physically in
   * there — while `buyable` is `sellable()`, which is that minus the bulls
   * already promised to reservations nobody has settled yet. They differ only
   * for the few blocks a reservation is in flight, and the difference is not
   * cosmetic: `reserve()` reverts `PoolTooSmall(count, free)` against
   * `sellable`, so clamping the count input on anything else offers a mint that
   * cannot go through.
   */
  const headlineSold = pen.isPen ? circulating : sold;
  const headlineSupply = pen.isPen ? SUPPLY : supply;
  const headlineLeft = pen.isPen ? pen.poolSize : Math.max(0, supply - sold);
  const buyable = pen.isPen ? pen.sellable : Math.max(0, supply - sold);

  const countsLoading = pen.isPen ? dropStateLoading || herd.isLoading : dropStateLoading;
  /** Every number above is real, from a read that actually landed. */
  const countsKnown = pen.isPen
    ? dropStateKnown && !herd.isLoading && !herd.unavailable && buyable !== null
    : dropStateKnown;
  const countsUnavailable = pen.isPen
    ? dropStateUnavailable || (!herd.isLoading && (herd.unavailable || pen.unavailable))
    : dropStateUnavailable;

  const soldOut = countsKnown && buyable === 0;
  const maxCount = Math.max(1, Math.min(20, buyable || 1));

  function retryDropState() {
    refetchSold();
    refetchMax();
    refetchPaused();
    herd.refetch();
    pen.refetch();
  }

  // Short TTL, shown — the BNB leg converts through Chainlink at PAY time
  // (DECISIONS.md §1), so a quote sitting stale on screen is a failed tx
  // waiting to happen. Refetch on a clock and surface the age.
  const {
    data: quote,
    dataUpdatedAt: quoteUpdatedAt,
    refetch: refetchQuote,
  } = useReadContract({
    address: mintDropAddress ?? undefined,
    abi: MintDropAbi,
    functionName: 'quote',
    args: [BigInt(count)],
    query: {
      enabled: !!mintDropAddress && dropStateKnown && !soldOut,
      refetchInterval: QUOTE_REFRESH_MS,
    },
  });
  const quoteAgeSeconds = quoteUpdatedAt ? Math.max(0, Math.round((Date.now() - quoteUpdatedAt) / 1000)) : undefined;
  // `MintDrop.quote(count)` -> (usdTotal1e18, bnbDue, bnbullDue, bnbUsd1e18).
  // FOUR values since `DECISIONS.md §26` dropped the stablecoin leg.
  const [usdTotal, bnbDue, bnbullDue] = (quote as
    | readonly [bigint, bigint, bigint, bigint]
    | undefined) ?? [undefined, undefined, undefined, undefined];

  const { decimals: bnbullDecimals } = useTokenDecimals(bnbullAddress as `0x${string}` | undefined);

  const { data: bnbullDiscountBps } = useReadContract({
    address: mintDropAddress ?? undefined,
    abi: MintDropAbi,
    functionName: 'discountBpsOf',
    args: bnbullAddress ? [bnbullAddress as `0x${string}`] : undefined,
    query: { enabled: !!mintDropAddress && !!bnbullAddress },
  });

  // Tier status derived from live `totalSold`, not guessed — a tier is
  // "live" once the previous tier's cap is met and this one's isn't yet.
  // Every integer field decodes as `bigint` regardless of its solidity
  // width (uint16 included) — never assume `number` off a contract read.
  const tierStatus = useMemo(() => {
    const rows = (tierRows ?? [])
      .map((r) => r.result as { upToSold: bigint; usdPrice: bigint } | undefined)
      .filter((t): t is { upToSold: bigint; usdPrice: bigint } => !!t);
    let prevCap = 0;
    return rows.map((tier) => {
      const cap = Number(tier.upToSold);
      const status: 'sold out' | 'live' | 'upcoming' =
        sold >= cap ? 'sold out' : sold >= prevCap ? 'live' : 'upcoming';
      prevCap = cap;
      return { tier, status };
    });
  }, [tierRows, sold]);

  const dueForAsset: Record<PayAsset, bigint | undefined> = {
    bnb: bnbDue,
    bnbull: bnbullDue,
  };
  const decimalsForAsset: Record<PayAsset, number | undefined> = {
    bnb: NATIVE_BNB_DECIMALS,
    bnbull: bnbullDecimals,
  };
  // A zero BNBULL quote is not an error, it is `DECISIONS.md §29`: four.meme
  // holds the token transfer-locked until its curve fills, so the leg is
  // present in the contract and simply not switched on. Say so, do not error.
  const bnbullUnavailable = bnbullDue === undefined || bnbullDue === 0n;

  /**
   * ⚠ RUNNING OUT OF MONEY IS NOT AN ERROR, AND IT USED TO RENDER AS ONE.
   *
   * A wallet that cannot cover the mint simulates as `EVM error: OutOfFunds`,
   * which carries no revert data — so `decodeRevert` bottoms out on the generic
   * "something has moved since this screen loaded, so reload and try again".
   * That sentence is actively wrong here: reloading never helps, and the player
   * is never told the one thing they could act on. So this is checked BEFORE the
   * click and said plainly.
   *
   * ⚠ AGAINST COST **PLUS GAS**, not the bare cost. A wallet holding exactly the
   * mint price still cannot pay for the block space, and that near-miss is the
   * most confusing one of the lot.
   */
  const { data: nativeBalance, isError: balanceFailed } = useBalance({
    address: account,
    chainId: CHAIN_ID,
    query: { enabled: !!account, refetchInterval: QUOTE_REFRESH_MS },
  });
  const bnbSendValue = bnbDue !== undefined ? withCushion(bnbDue) : undefined;
  const bnbNeeded = bnbSendValue !== undefined ? bnbSendValue + MINT_GAS_HEADROOM_WEI : undefined;
  /**
   * true / false only once the balance and the quote have both actually landed.
   * ⚠ ONLY a definitive shortfall disables the button. A failed or in-flight
   * balance read leaves it alone — the same rule the marketplace peg and the
   * bull page follow: never tell somebody they cannot do a thing off a call
   * that did not come back.
   */
  const shortOfBnb: boolean =
    asset === 'bnb' &&
    !balanceFailed &&
    nativeBalance !== undefined &&
    bnbNeeded !== undefined &&
    nativeBalance.value < bnbNeeded;

  /** How many this wallet could actually pay for, for the "try N instead" nudge. */
  const affordableCount = useMemo(() => {
    if (!shortOfBnb || bnbDue === undefined || bnbDue === 0n || nativeBalance === undefined) {
      return null;
    }
    const perBull = withCushion(bnbDue) / BigInt(count); // count >= 1 by construction
    if (perBull === 0n) return null;
    const spendable = nativeBalance.value > MINT_GAS_HEADROOM_WEI
      ? nativeBalance.value - MINT_GAS_HEADROOM_WEI
      : 0n;
    const n = Number(spendable / perBull);
    return n >= 1 && n < count ? n : null;
  }, [shortOfBnb, bnbDue, nativeBalance, count]);

  const approvalToken = asset === 'bnbull' ? (bnbullAddress as `0x${string}` | undefined) : undefined;
  const approvalRequired = asset === 'bnbull' ? bnbullDue : undefined;
  const { needsApproval, approve, isApproving, refetchAllowance } = useErc20Approval(
    approvalToken,
    mintDropAddress ?? undefined,
    approvalRequired,
  );

  const {
    writeContractAsync,
    isPending: isMinting,
    data: mintHash,
    reset: resetMint,
  } = useWriteContract();
  const { preflight, checking } = usePreflight();
  /**
   * ⚠ DECODED, NEVER `mintError.message`. This panel used to render the wallet's
   * own string straight out of wagmi, which on a reverting call is the rpc's
   * complaint about a gas number rather than the reason the mint failed.
   */
  const [mintRevert, setMintRevert] = useState<DecodedRevert | null>(null);
  const {
    data: mintReceipt,
    isLoading: isConfirmingMint,
    isSuccess: mintConfirmed,
  } = useWaitForTransactionReceipt({ hash: mintHash });

  /**
   * THE BULLS THAT WERE JUST MINTED, read out of the receipt.
   *
   * ⚠ `mintWithBNB` / `mintWithBNBULL` DO return `uint256[]`, and it is
   * unreachable from here. A return value only exists inside the EVM; a
   * broadcast transaction hands the client a receipt, and a receipt carries
   * logs, not return data. So the ids come out of an event.
   *
   * ⚠ THE EVENT IS `BullMinted`, NOT `Transfer`, AND THAT IS THE WHOLE POINT.
   * `Bulls.sol` emits a DEDICATED `BullMinted(uint256 indexed tokenId, address
   * indexed owner, string name)` on every mint (and on `mintKing`, which emits
   * it alongside `KingMinted`, so the 1/1 needs no special case here).
   *
   * The ERC-721 `Transfer` shares its topic0 — `keccak("Transfer(address,
   * address,uint256)")` — with the ERC-20 `Transfer`, and a mint receipt is
   * FULL of ERC-20 transfers: the 20% BNBULL leg, the 10% BNB leg, the router
   * hops and the splitters all emit one. Decoding on that topic means every
   * one of those is a candidate and the only things standing between a
   * transfer `value` being read as a token id are hand-written filters. The
   * dedicated event removes the hazard instead of guarding it: nothing else in
   * the transaction can produce this signature.
   *
   * Filtered on the `Bulls` address and on `owner == you` anyway — this page
   * always mints `to = account`, so anything else did not come from this
   * click and the reveal's "yours" would not be true of it.
   */
  const legacyMintedIds = useMemo(() => {
    if (!mintReceipt || mintReceipt.status !== 'success' || !bullsAddress || !account) return [];
    const bulls = bullsAddress.toLowerCase();
    const to = account.toLowerCase();
    const ids = parseEventLogs({ abi: BullsAbi, eventName: 'BullMinted', logs: mintReceipt.logs })
      .filter(
        (log) =>
          log.address.toLowerCase() === bulls && log.args.owner.toLowerCase() === to,
      )
      .map((log) => Number(log.args.tokenId))
      // The art tables cover 1..501. Anything outside that is not a bull this
      // build can draw, and guessing at it would be inventing a sprite.
      .filter(isValidBullId);
    return [...new Set(ids)].sort((a, b) => a - b);
  }, [mintReceipt, bullsAddress, account]);

  /**
   * THE RESERVATION, read out of the receipt — the pen path's answer to
   * `BullMinted`.
   *
   * ⚠ UNDER THE PEN, `BullMinted` IS ABSENT FROM EVERY SUCCESSFUL MINT, AND
   * WITHOUT THIS THE PANEL FALLS INTO ITS DEGRADED FALLBACK EVERY SINGLE TIME.
   *
   * `MintDrop._mintAndEmit` branches on whether a pen is wired. Wired, it calls
   * `BullPen.reserve` and emits `BullsReserved` INSTEAD of `BullSold`, and no
   * bull is minted in the buyer's transaction at all — so `Bulls` emits nothing,
   * the `BullMinted` parse above returns an empty array, and the panel would
   * render "no BullMinted event was in the receipt this page could read" to a
   * buyer whose mint went perfectly. That message is the one thing on this page
   * that reads as "your money went somewhere and we do not know where".
   *
   * ⚠ AND THE RETURN VALUE IS STILL UNREACHABLE, FOR THE SAME REASON AS EVER: a
   * return value only exists inside the EVM, a broadcast transaction hands the
   * client a receipt, and a receipt carries logs. `mintWithBNB` returns an EMPTY
   * array on this path anyway, deliberately — there is genuinely nothing to
   * return, because nothing has been drawn yet.
   *
   * Filtered on the `MintDrop` address for the same reason the legacy parse
   * filters on `Bulls`: nothing else in the transaction can produce this
   * signature from that address.
   */
  const reservationId = useMemo<bigint | null>(() => {
    if (!pen.isPen || !mintReceipt || mintReceipt.status !== 'success' || !mintDropAddress) {
      return null;
    }
    const drop = mintDropAddress.toLowerCase();
    const hit = parseEventLogs({
      abi: MintDropAbi,
      eventName: 'BullsReserved',
      logs: mintReceipt.logs,
    }).find((log) => log.address.toLowerCase() === drop);
    return hit ? (hit.args.reservationId as bigint) : null;
  }, [pen.isPen, mintReceipt, mintDropAddress]);

  const reservation = useReservation(reservationId);

  /**
   * The permissionless rescue writes, shared with the row this panel renders
   * while the draw is out. ⚠ `reservation.refetch` on confirm rather than a
   * blanket invalidation: the settle case is handled by the effect below, and
   * `armFallback` / `pinFallbackSeed` change nothing anywhere else on the site,
   * so invalidating every read on the page for them would be a full refetch
   * storm for a state change only this one row cares about.
   */
  const penWrites = usePenWrites(() => reservation.refetch());

  /**
   * ⚠ THE IDS COME FROM `drawnIds(reservationId)`, NOT FROM THE `Settled` EVENT.
   * The event is in a transaction the buyer very likely did not send (settling
   * is permissionless, and a keeper or the person behind them in the queue may
   * well have pressed it first), so there is no receipt here to parse. The
   * mapping read answers regardless of who paid the gas, and it answers after a
   * reload too.
   */
  const penMintedIds = useMemo(() => {
    if (!reservation.settled) return [];
    return [...new Set(reservation.tokenIds.filter(isValidBullId))].sort((a, b) => a - b);
  }, [reservation.settled, reservation.tokenIds]);

  const mintedIds = pen.isPen ? penMintedIds : legacyMintedIds;

  /**
   * THE REVEAL'S NUMBERS, batch-loaded off chain — one multicall for the whole
   * batch, the same shape fefers' `useBatchOutlaws` uses.
   *
   * Nothing here is derived from the sprite. The rating, the record and the
   * weapon's damage and speed are contract state, so they are READ; the tier,
   * the name and the art are the deterministic tables the chain commits to.
   * There is no third source and no fallback that makes a number up.
   */
  const {
    data: mintedRows,
    isLoading: loadingMintedRows,
    error: revealError,
  } = useReadContracts({
    contracts: mintedIds.flatMap((id) => [
      {
        address: bullsAddress ?? undefined,
        abi: BullsAbi,
        functionName: 'getBull' as const,
        args: [BigInt(id)] as const,
      },
      {
        address: bullsAddress ?? undefined,
        abi: BullsAbi,
        functionName: 'getBullWeapon' as const,
        args: [BigInt(id)] as const,
      },
    ]),
    query: { enabled: !!bullsAddress && mintedIds.length > 0 },
  });

  const minted = useMemo<MintedBull[]>(
    () =>
      mintedIds.map((id, i) => {
        const bullRes = mintedRows?.[i * 2];
        const weaponRes = mintedRows?.[i * 2 + 1];
        return {
          id,
          bull: bullRes?.status === 'success' ? (bullRes.result as unknown as ChainBull) : undefined,
          weapon:
            weaponRes?.status === 'success'
              ? (weaponRes.result as unknown as ChainWeapon)
              : undefined,
        };
      }),
    [mintedIds, mintedRows],
  );

  /**
   * sign → mine → [draw] → reveal → success, the state machine off fefers' mint
   * page, ported in the same order with the same gates:
   *
   *   isSigning                         → signing
   *   receipt.status !== 'success'      → reverted
   *   txHash && isMining                → mining
   *   pen wired, reservation unsettled  → drawing        ← pen only
   *   ids decoded, batch still loading  → revealing
   *   every bull resolved               → success
   *
   * Fefers' `phase` derivation puts the error legs first, then approve, then
   * sign/mine, then the reveal — and it only shows the fefers once EVERY id in
   * the batch has resolved (`mintedOutlaws.length === mintedTokenIds.length`),
   * so a batch of five never renders four and a hole. Same here.
   *
   * Before this the page rendered one line of text on a confirmed mint and the
   * buyer never saw what they bought.
   *
   * ⚠ `drawing` SITS BETWEEN A CONFIRMED TRANSACTION AND KNOWN IDS, WHICH IS A
   * STATE THAT COULD NOT EXIST BEFORE THE PEN. On the legacy path a confirmed
   * mint carries its ids in the receipt, so `mintConfirmed && !mintedIds.length`
   * meant something had genuinely gone wrong and the degraded "no BullMinted
   * event" line was the right answer. Under the pen that combination is the
   * NORMAL, EXPECTED state for a minute or so, and rendering the old fallback
   * there would tell every single buyer that their receipt looked broken.
   */
  const mintReverted = !!mintReceipt && mintReceipt.status !== 'success';
  const revealFailed = !!revealError && mintedIds.length > 0;
  const revealReady =
    mintedIds.length > 0 && !loadingMintedRows && minted.every((m) => m.bull !== undefined);
  /**
   * Paid for, reserved, not yet drawn and handed over.
   *
   * ⚠ `!reservation.refunded` IS LOAD-BEARING. A refunded reservation is never
   * settled, so without it the panel would sit on "your bulls are being drawn"
   * forever over money that came back hours ago — the exact screen this whole
   * refund flow exists to prevent.
   */
  /**
   * ⚠ THE CONFIRMED RECEIPT IS READ ALONGSIDE THE POLLED STATE. `rescueState`
   * is on an 8 second clock, so between the refund confirming and the next poll
   * this panel would still be narrating "your bulls are being drawn" over money
   * that is already back in the wallet. Matched on the key because one
   * `usePenWrites` serves every reservation on the page.
   */
  const justRefunded =
    reservationId !== null &&
    penWrites.lastDone?.what === 'refund' &&
    penWrites.lastDone.key === reservationId.toString();
  const wasRefunded = reservation.refunded || justRefunded;

  const awaitingDraw =
    pen.isPen && reservationId !== null && !reservation.settled && !wasRefunded;
  const mintPhase: MintPhase = mintReverted
    ? 'reverted'
    : isMinting
      ? 'signing'
      : mintHash && isConfirmingMint
        ? 'mining'
        : wasRefunded
          ? 'refunded'
          : awaitingDraw
            ? 'drawing'
            : mintConfirmed && mintedIds.length > 0
              ? revealReady || revealFailed
                ? 'success'
                : 'revealing'
              : mintConfirmed
                ? 'success'
                : 'idle';

  /**
   * A confirmed mint changes `totalSold`, the tier that is live, and which
   * bulls the wallet owns. Every one of those is a cached `useReadContract` /
   * `useReadContracts` somewhere on the site, and without this they sit on
   * their own refetch clocks (or none at all, for the ones that never poll) —
   * so a buyer had to reload the page to see anything move. wagmi keys its read
   * queries under these two prefixes, and react-query matches a key prefix, so
   * this invalidates every contract read the app holds without reaching into
   * hooks that are not ours to edit.
   */
  useEffect(() => {
    if (!mintConfirmed) return;
    queryClient.invalidateQueries({ queryKey: ['readContract'] });
    queryClient.invalidateQueries({ queryKey: ['readContracts'] });
  }, [mintConfirmed, mintHash, queryClient]);

  /**
   * ⚠ AND AGAIN WHEN THE DRAW LANDS, WHICH IS A SECOND, LATER MOMENT.
   *
   * On the pen path the buyer's own transaction changes almost nothing a player
   * can see: no bull moves, no balance of theirs changes, the pool does not
   * shrink. All of that happens in `settle`, which is a DIFFERENT transaction
   * and very often somebody else's. So the invalidation above fires too early
   * and there is nothing to fire it again — a delivered bull would sit invisible
   * until a reload, which is exactly the anxiety this whole flow exists to
   * remove. Keyed on `reservation.settled` so it runs once, whoever settled it.
   */
  useEffect(() => {
    if (!reservation.settled) return;
    queryClient.invalidateQueries({ queryKey: ['readContract'] });
    queryClient.invalidateQueries({ queryKey: ['readContracts'] });
  }, [reservation.settled, queryClient]);

  /**
   * ⚠ `chainId: CHAIN_ID` IS LOAD-BEARING ON THE BNB LEG. Omitted, wagmi hands
   * viem `chain: null`, viem skips `assertCurrentChain`, and `value` is sent to
   * an address that holds no code on whatever chain the wallet is actually on.
   * That BNB is gone. With it pinned, viem throws before signing.
   */
  /**
   * ⚠ SIMULATED FIRST, and this is the write where the old behaviour was worst.
   *
   * A mint quote is a Chainlink conversion with a cushion on top, and every
   * input to it moves: the price ladder steps at a mint boundary somebody else
   * can cross first (`PriceTooHigh`), the feed goes stale (`OracleStale`), the
   * drop sells out (`SupplyExhausted`), the swap route thins out
   * (`PoolTooThin`, `SwapOutBelowMin`). Each of those is a sentence a player
   * can act on, and this panel used to render `mintError.message` instead —
   * which on a reverting call is the rpc's complaint about a gas number.
   */
  async function handleMint() {
    if (!mintDropAddress || !account || wrongNetwork) return;
    setMintRevert(null);

    /**
     * ⚠ RE-READ THE QUOTE, DO NOT TRUST THE RENDERED ONE. The price is pegged in
     * DOLLARS and converts through Chainlink at PAY time, so the required wei
     * moves every block: three reads seconds apart on mainnet gave 16565116…,
     * 16561255…, 16562411…. The number on screen was fetched up to
     * QUOTE_REFRESH_MS ago, and longer if the tab was ever backgrounded — react
     * -query pauses its interval there. Sending that stale figure is how an
     * honest mint bounces on `msg.value < due`, which surfaces as the generic
     * "something has moved since this screen loaded" and reads as a broken site.
     *
     * The cushion below absorbs ordinary drift; this removes the stale baseline
     * the cushion would otherwise be applied to. A failed refetch is not fatal —
     * fall back to the rendered value and let the preflight have the last word.
     */
    let freshBnbDue = bnbDue;
    if (asset === 'bnb') {
      try {
        const again = await refetchQuote();
        const row = again.data as readonly [bigint, bigint, bigint, bigint] | undefined;
        if (row?.[1] !== undefined) freshBnbDue = row[1];
      } catch {
        /* keep the rendered quote; the preflight still guards the send */
      }
    }

    const call =
      asset === 'bnb' && freshBnbDue !== undefined
        ? {
            address: mintDropAddress,
            abi: MintDropAbi,
            functionName: 'mintWithBNB' as const,
            args: [account, BigInt(count)] as const,
            value: withCushion(freshBnbDue),
          }
        : asset === 'bnbull'
          ? {
              address: mintDropAddress,
              abi: MintDropAbi,
              functionName: 'mintWithBNBULL' as const,
              args: [account, BigInt(count)] as const,
            }
          : null;
    if (!call) return;

    const pre = await preflight(call);
    if (!pre.ok) {
      setMintRevert(pre.error);
      return;
    }

    try {
      if (asset === 'bnb' && freshBnbDue !== undefined) {
        await writeContractAsync({
          address: mintDropAddress,
          abi: MintDropAbi,
          chainId: CHAIN_ID,
          functionName: 'mintWithBNB',
          args: [account, BigInt(count)],
          value: withCushion(freshBnbDue),
        });
      } else {
        await writeContractAsync({
          address: mintDropAddress,
          abi: MintDropAbi,
          chainId: CHAIN_ID,
          functionName: 'mintWithBNBULL',
          args: [account, BigInt(count)],
        });
      }
    } catch (e) {
      setMintRevert(decodeRevert(e));
    }
  }

  if (!mintDropAddress) {
    return (
      <div>
        <NotDeployed what="the mint" className="mb-8" />
        <h3 className="bull-header text-lg">the ladder</h3>
        <p className="mt-2 max-w-2xl text-bull-text-dim">
          $10 for the first hundred, $75 for the last hundred, and the price climbs by how many
          have sold rather than by token id. this is the table the mint contract is wired with,
          not a live read, because there is nothing to read yet. the day it is deployed these
          rows come straight off chain.
        </p>
        <div className="mt-6 overflow-x-auto">
          <table className="w-full min-w-[420px] border-collapse text-sm">
            <thead>
              <tr className="border-b border-bull-border text-left font-mono text-xs uppercase tracking-wide text-bull-text-faint">
                <th className="py-2 pr-4">up to sold</th>
                <th className="py-2 pr-4">price</th>
                <th className="py-2 pr-4">bnbull leg (−10%)</th>
              </tr>
            </thead>
            <tbody>
              {STATIC_LADDER.map((row) => (
                <tr key={row.upToSold} className="border-b border-bull-border/60">
                  <td className="py-2 pr-4 font-mono">{row.upToSold}</td>
                  <td className="py-2 pr-4 font-mono text-bull-gold">${row.usd}</td>
                  <td className="py-2 pr-4 font-mono text-bull-text-dim">${(row.usd * 0.9).toFixed(2)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        {/* ⚠ THE THIRD COLUMN IS NOT AVAILABLE AT LAUNCH AND MUST SAY SO.
            `DECISIONS.md §29` + `§28.1`: four.meme holds BNBULL transfer-locked
            until its curve fills, so nobody can pay a mint in it, discount or
            no discount. A price column with no caveat reads as a choice a buyer
            has on day one, and they do not. The discount itself is real and is
            `§2`, minting only, `§39` having removed it from fighting. */}
        <p className="mt-3 max-w-2xl text-xs text-bull-text-faint">
          {CURRENCY.bnbullPending} the 10% off is a mint discount only, so it is the third
          column above and nothing else: a fight costs the same in either currency.
        </p>
      </div>
    );
  }

  return (
    <div>
      {/* ⚠ THE HEADLINE COUNTS ARE NOT `totalSold`. See the derivation above:
          under the pen this contract's own sales counter restarts at zero while
          the collection is already part-sold, so the numbers here come off the
          circulating set and the pen's own pool instead. The LADDER below still
          reads `totalSold`, because the ladder really is defined against this
          drop's sales and that has not changed. */}
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <p className="font-mono text-sm text-bull-text-dim">
          {countsLoading ? (
            'loading…'
          ) : countsUnavailable ? (
            '— / — minted'
          ) : (
            <>
              <span className="text-bull-gold">{headlineSold}</span> / {headlineSupply} minted
            </>
          )}
        </p>
        <p className="font-mono text-sm text-bull-text-faint">
          {countsKnown && headlineLeft !== null ? `${headlineLeft} left` : ''}
        </p>
      </div>
      <div className="mt-2 h-2 w-full overflow-hidden rounded-full bg-bull-panel">
        <div
          className="h-full bg-bull-gold transition-all"
          style={{
            width:
              !countsKnown || !headlineSupply
                ? '0%'
                : `${Math.min(100, (headlineSold / headlineSupply) * 100)}%`,
          }}
        />
      </div>

      {/* ⚠ MOUNTED ABOVE THE MINT BUTTON AND OUTSIDE EVERY BRANCH BELOW. A
          buyer who comes back to this page with bulls still being drawn has to
          see it before they consider paying again — and it must not vanish
          because the drop sold out, because minting got paused, or because a
          read failed. It renders nothing at all on the legacy path.
          ⚠ `excludeIds` HANDS THE RESERVATION THIS PANEL JUST CREATED BACK TO
          THE OUTCOME BLOCK UNDER THE MINT BUTTON, so one mint is narrated in one
          place. Everything the buyer did NOT just create still shows here. */}
      <PendingReservations
        className="mt-6"
        excludeIds={reservationId !== null ? [reservationId] : undefined}
      />

      <div className="mt-8 overflow-x-auto">
        <table className="w-full min-w-[520px] border-collapse text-sm">
          <thead>
            <tr className="border-b border-bull-border text-left font-mono text-xs uppercase tracking-wide text-bull-text-faint">
              <th className="py-2 pr-4">up to sold</th>
              <th className="py-2 pr-4">price</th>
              <th className="py-2 pr-4">status</th>
            </tr>
          </thead>
          <tbody>
            {tierStatus.map(({ tier, status }) => (
              <tr key={String(tier.upToSold)} className="border-b border-bull-border/60">
                <td className="py-2 pr-4 font-mono">{Number(tier.upToSold)}</td>
                <td className="py-2 pr-4 font-mono text-bull-gold">{formatUsd1e18(tier.usdPrice)}</td>
                <td
                  className={`py-2 pr-4 font-mono text-xs uppercase ${
                    status === 'live'
                      ? 'text-bull-gold'
                      : status === 'sold out'
                        ? 'text-bull-text-faint'
                        : 'text-bull-text-dim'
                  }`}
                >
                  {status}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {/* ⚠ These three gates use the SAME counts as the header, so the page can
          never offer a mint off numbers it just admitted it could not read. On
          the legacy path `countsLoading` / `countsUnavailable` are literally
          `dropStateLoading` / `dropStateUnavailable`, so nothing here changes
          until a pen is wired. */}
      {countsLoading ? (
        <p className="mt-8 rounded border border-bull-border bg-bull-panel px-4 py-3 text-sm text-bull-text-dim">
          loading the live drop state…
        </p>
      ) : countsUnavailable ? (
        <div className="mt-8 rounded border border-bull-border bg-bull-panel px-4 py-3 text-sm text-bull-text-dim">
          <p>
            couldn&apos;t read the drop off the chain just now. that is this page failing to
            reach an rpc, not the drop being over, so nothing here claims to know how many are
            left.
          </p>
          <button
            type="button"
            onClick={retryDropState}
            className="mt-3 rounded-full border border-bull-gold px-3 py-1.5 text-xs font-medium text-bull-gold"
          >
            try again
          </button>
        </div>
      ) : soldOut ? (
        <p className="mt-8 rounded border border-bull-border bg-bull-panel px-4 py-3 text-sm text-bull-text-dim">
          the drop is sold out.
        </p>
      ) : isPaused ? (
        <p className="mt-8 rounded border border-bull-gold/30 bg-bull-panel px-4 py-3 text-sm text-bull-text-dim">
          <strong className="bull-header text-bull-gold">minting has not opened yet.</strong> the
          contract is deployed and paused, which is how it ships: the drop opens in one
          transaction when everything else is wired and checked. the ladder above is live and
          read off that contract. there is nothing to click until it does.
        </p>
      ) : (
        <div className="mt-8 rounded border border-bull-border bg-bull-panel p-4">
          <div className="flex items-center gap-3">
            <label className="font-mono text-xs uppercase tracking-wide text-bull-text-faint">
              count
            </label>
            <input
              type="number"
              min={1}
              max={maxCount}
              value={count}
              onChange={(e) => setCount(Math.max(1, Math.min(maxCount, Number(e.target.value) || 1)))}
              className="w-20 rounded border border-bull-border bg-bull-bg px-2 py-1 font-mono text-sm"
            />
            <span className="text-xs text-bull-text-faint">max {maxCount} per tx</span>
          </div>

          <p className="mt-4 font-mono text-sm text-bull-text-dim">
            total price: <span className="text-bull-text">{formatUsd1e18(usdTotal)}</span>
          </p>

          <div className="mt-4 flex gap-2">
            <button
              onClick={() => setAsset('bnb')}
              className={`rounded-full border px-3 py-1.5 text-xs font-medium ${asset === 'bnb' ? 'border-bull-gold text-bull-gold' : 'border-bull-border text-bull-text-dim'}`}
            >
              bnb
            </button>
            <button
              onClick={() => setAsset('bnbull')}
              disabled={bnbullUnavailable}
              title={bnbullUnavailable ? CURRENCY.bnbullPending : undefined}
              className={`rounded-full border px-3 py-1.5 text-xs font-medium disabled:opacity-40 ${asset === 'bnbull' ? 'border-bull-gold text-bull-gold' : 'border-bull-border text-bull-text-dim'}`}
            >
              {/* ⚠ THE LABEL ITSELF SAYS "not yet". A greyed button that still
                  advertises a discount reads as a thing you failed to click,
                  and players kept clicking it. The leg cannot work at all until
                  four.meme graduates: the token is transfer-locked (`_mode()=1`)
                  and `mintWithBNBULL` does a `transferFrom`, so it is closed,
                  not flaky. */}
              bnbull
              {bnbullUnavailable
                ? ' (not yet)'
                : bnbullDiscountBps
                  ? ` (−${formatBps(bnbullDiscountBps)})`
                  : ''}
            </button>
          </div>

          {bnbullUnavailable && (
            <p className="mt-2 text-[11px] text-bull-text-faint">{CURRENCY.bnbullPending}</p>
          )}

          <p className="mt-4 font-mono text-lg text-bull-gold">
            {formatToken(dueForAsset[asset], decimalsForAsset[asset])}{' '}
            <span className="text-sm text-bull-text-dim">{asset}</span>
          </p>
          <p className="mt-1 font-mono text-[11px] text-bull-text-faint">
            {quoteAgeSeconds !== undefined ? `quoted ${quoteAgeSeconds}s ago` : 'quoting…'} · refreshes
            every {QUOTE_REFRESH_MS / 1000}s · send a small cushion, the surplus is refunded
          </p>

          <WrongNetworkNotice className="mt-4" />

          {/* ⚠ A CALM PROMPT, NOT AN ERROR. Running out of money is a normal
              thing that happens to people, not a fault, and it is the one
              failure the player can actually fix. Shown before the click so the
              wallet never opens on a transaction that cannot pay. */}
          {shortOfBnb && nativeBalance && bnbNeeded !== undefined && (
            <div className="mt-4 rounded border border-bull-gold/30 bg-bull-bg px-4 py-3 text-sm text-bull-text-dim">
              <p>
                <strong className="bull-header text-bull-gold">not enough bnb.</strong> minting{' '}
                {count} {count === 1 ? 'bull' : 'bulls'} costs about{' '}
                <span className="font-mono text-bull-text">
                  {formatToken(bnbSendValue, NATIVE_BNB_DECIMALS)}
                </span>{' '}
                bnb plus gas, and this wallet holds{' '}
                <span className="font-mono text-bull-text">
                  {formatToken(nativeBalance.value, NATIVE_BNB_DECIMALS)}
                </span>{' '}
                bnb. top it up and the button comes back on its own.
              </p>
              {affordableCount !== null && (
                <button
                  type="button"
                  onClick={() => setCount(affordableCount)}
                  className="mt-3 rounded-full border border-bull-gold px-3 py-1.5 text-xs font-medium text-bull-gold"
                >
                  mint {affordableCount} instead
                </button>
              )}
            </div>
          )}

          {!account ? (
            <p className="mt-4 text-sm text-bull-text-faint">connect a wallet to mint.</p>
          ) : asset !== 'bnb' && needsApproval ? (
            <button
              onClick={async () => {
                // ⚠ CAUGHT. This used to be a bare `await approve()`, so a
                // rejected or failing approval threw into an unhandled promise
                // rejection and the player saw NOTHING AT ALL — the silent end
                // of the same bug class as "gas limit too high".
                try {
                  await approve();
                  refetchAllowance();
                } catch (e) {
                  setMintRevert(decodeRevert(e));
                }
              }}
              disabled={isApproving || wrongNetwork}
              className="bull-btn mt-4 w-full"
            >
              {isApproving ? 'approving…' : 'approve bnbull'}
            </button>
          ) : (
            <button
              onClick={handleMint}
              disabled={isMinting || isConfirmingMint || wrongNetwork || shortOfBnb}
              className="bull-btn bull-btn-pulse mt-4 w-full"
            >
              {wrongNetwork
                ? 'wrong network'
                : shortOfBnb
                  ? 'not enough bnb'
                  : isMinting || isConfirmingMint
                    ? 'minting…'
                    : checking
                      ? 'checking…'
                      : `mint ${count}`}
            </button>
          )}
          <RevertNotice error={mintRevert} className="mt-3" />
        </div>
      )}

      {/* ⚠ OUTSIDE the drop-state branch on purpose. Buying the last bulls in
          the drop flips `soldOut` true the moment the reads refresh, which
          swaps the whole panel above for "the drop is sold out." — and if the
          reveal lived in there it would vanish in the same render, taking the
          payoff away from the one buyer who closed the drop out.
          ⚠ And DIRECTLY BELOW THE MINT BUTTON, not on another page and not in
          a modal. That placement is the whole request. */}
      <MintOutcome
        phase={mintPhase}
        minted={minted}
        txHash={mintHash}
        revealFailed={revealFailed}
        onMintAnother={resetMint}
        isPen={pen.isPen}
        reservationId={reservationId}
        reservation={reservation}
        penWrites={penWrites}
      />
    </div>
  );
}

/**
 * sign · mine · reveal · done, or sign · mine · draw · reveal · done under the
 * pen. Ported from fefers' `PhaseIndicator`: a handful of words that tell a
 * buyer which of the several different ways this can be slow is currently
 * happening.
 *
 * ⚠ THE FIFTH STEP IS ONLY THERE WHEN THE PEN IS. Showing "draw" on the legacy
 * path would promise a stage that never arrives and leave the strip stuck one
 * short of done forever.
 */
function MintSteps({ phase, isPen }: { phase: MintPhase; isPen: boolean }) {
  const steps = isPen
    ? (['sign', 'mine', PEN.drawStep, 'reveal', 'done'] as const)
    : (['sign', 'mine', 'reveal', 'done'] as const);
  const order: MintPhase[] = isPen
    ? ['signing', 'mining', 'drawing', 'revealing', 'success']
    : ['signing', 'mining', 'revealing', 'success'];
  const activeIdx = order.indexOf(phase);
  if (activeIdx < 0) return null;
  return (
    <div className="flex flex-wrap items-center gap-2 font-mono text-[11px] uppercase tracking-wide">
      {steps.map((step, i) => (
        <span
          key={step}
          className={
            i < activeIdx
              ? 'text-bull-text-dim'
              : i === activeIdx
                ? 'text-bull-gold'
                : 'text-bull-text-faint'
          }
        >
          {i < activeIdx ? '✓' : i === activeIdx ? '●' : '○'} {step}
          {i < steps.length - 1 ? ' ·' : ''}
        </span>
      ))}
    </div>
  );
}

/**
 * Everything that happens after the mint button is clicked. Ported from
 * fefers' mint page: `PhaseIndicator` + `StatusBlock` + `RevertedBlock` +
 * `SuccessBlock`, in that order and with the same gates.
 */
function MintOutcome({
  phase,
  minted,
  txHash,
  revealFailed,
  onMintAnother,
  isPen,
  reservationId,
  reservation,
  penWrites,
}: {
  phase: MintPhase;
  minted: readonly MintedBull[];
  txHash: `0x${string}` | undefined;
  revealFailed: boolean;
  onMintAnother: () => void;
  isPen: boolean;
  reservationId: bigint | null;
  reservation: ReservationView;
  penWrites: ReturnType<typeof usePenWrites>;
}) {
  if (phase === 'idle') return null;

  const txLink = txHash ? (
    <a
      href={`${explorerBaseUrl()}/tx/${txHash}`}
      target="_blank"
      rel="noreferrer noopener"
      className="font-mono text-[11px] text-bull-gold hover:underline"
    >
      view the transaction
    </a>
  ) : null;

  if (phase === 'reverted') {
    return (
      <div className="mt-6 rounded border border-bull-red/40 bg-bull-red/10 p-4">
        <p className="bull-header text-bull-red">the mint reverted.</p>
        <p className="mt-2 text-sm text-bull-text-dim">
          it landed in a block and failed there, so nothing was minted and nothing was charged
          beyond gas. either the drop closed out under you, minting was paused, or the quote
          went stale. read the price again and try once more.
        </p>
        {txLink && <p className="mt-3">{txLink}</p>}
        <button
          type="button"
          onClick={onMintAnother}
          className="mt-3 block rounded-full border border-bull-gold px-3 py-1.5 text-xs font-medium text-bull-gold"
        >
          try again
        </button>
      </div>
    );
  }

  /**
   * THE REFUND DIALOGUE, RIGHT WHERE THE BUYER IS ALREADY LOOKING.
   *
   * ⚠ IT SITS DIRECTLY UNDER THE MINT BUTTON, NOT IN A TOAST AND NOT ONLY IN
   * THE BANNER AT THE TOP. Owner's ask, verbatim: "as long as a dialogue shows
   * on screen what the error was and that their funds are safu and been
   * returned straight away and they should mint again". The same dialogue is
   * rendered by `PendingReservations` off the connected address alone, so it
   * also survives a reload and reaches a second device; this placement is what
   * makes it the first thing seen rather than something to go and find.
   *
   * ⚠ "mint again" IS A RESET, NOT A LINK. They are already on the mint page,
   * so a link to it would look like a dead button. `onMintAnother` clears the
   * outcome and puts the live form back with the ladder and the quote on it.
   */
  if (phase === 'refunded') {
    return (
      <div className="mt-6">
        <RefundedDialogue res={reservation} onMintAgain={onMintAnother} />
        <RevertNotice error={penWrites.error} className="mt-3" />
        {txLink && <p className="mt-3">{txLink}</p>}
      </div>
    );
  }

  /**
   * THE DRAW. The money is gone, the sale is final, and nobody — including us —
   * knows which bulls yet.
   *
   * ⚠ THE ROW BELOW IS NOT DECORATION. It reports what the reservation is
   * actually waiting on and, in the three states that have one, offers the
   * permissionless button that unsticks it. The pen holds no money and has no
   * refund path, so a reservation that never settles is the single failure here
   * that costs somebody real money — and the escape was built so that the buyer
   * themselves can always take it.
   *
   * ⚠ AND THE SAME THING IS RENDERED BY `PendingReservations` ABOVE, OFF THE
   * CONNECTED ADDRESS ALONE. This block is the convenience; that one is the
   * guarantee. If this tab closes, the banner still finds it.
   */
  if (phase === 'drawing') {
    return (
      <div className="mt-6 rounded border border-bull-gold/40 bg-bull-panel p-4">
        <MintSteps phase={phase} isPen={isPen} />
        <p className="bull-header mt-2 text-bull-gold">paid. your bulls are being drawn.</p>
        <p className="mt-2 text-sm text-bull-text-dim">{PEN.why}</p>
        {reservationId !== null && (
          <div className="mt-3">
            <ReservationRow reservationId={reservationId} writes={penWrites} compact />
          </div>
        )}
        <RevertNotice error={penWrites.error} className="mt-3" />
        {txLink && <p className="mt-3">{txLink}</p>}
      </div>
    );
  }

  if (phase === 'signing' || phase === 'mining' || phase === 'revealing') {
    const body =
      phase === 'signing'
        ? 'open your wallet and confirm the mint. nothing has been sent yet.'
        : phase === 'mining'
          ? 'in a block, waiting on the confirmation.'
          : minted.length === 1
            ? `checking bull #${minted[0]!.id} papers, one sec.`
            : `checking all ${minted.length} sets of papers, one sec.`;
    return (
      <div className="mt-6 rounded border border-bull-border bg-bull-panel p-4">
        <MintSteps phase={phase} isPen={isPen} />
        <p className="mt-2 text-sm text-bull-text-dim">{body}</p>
        {txLink && <p className="mt-3">{txLink}</p>}
      </div>
    );
  }

  if (minted.length === 0) {
    /**
     * The transaction succeeded and we cannot name an id. Say only that, and do
     * not draw a bull we cannot name.
     *
     * ⚠ THE TWO PATHS FAIL FOR COMPLETELY DIFFERENT REASONS AND MUST NOT SHARE
     * A SENTENCE. On the legacy path the ids ride in the receipt, so getting
     * here means the receipt genuinely lacked a `BullMinted` — worth naming the
     * event, because that is a real anomaly somebody may need to report. On the
     * pen path the receipt NEVER carries ids and is not supposed to; getting
     * here means the reservation could not be read back, which is an rpc
     * problem, and naming `BullMinted` would send a reader hunting for an event
     * that was never going to be there.
     */
    return isPen ? (
      <p className="mt-6 text-sm text-bull-gold">
        minted. this page could not read your reservation back off the chain just now, which is
        an rpc having a moment rather than anything wrong with the mint. it will show up in the
        banner at the top of this page on its own, or{' '}
        <Link href="/bulls?filter=mine" className="underline hover:text-bull-gold-hover">
          browse your herd
        </Link>
        .
      </p>
    ) : (
      <p className="mt-6 text-sm text-bull-gold">
        minted. no <span className="font-mono">BullMinted</span> event was in the receipt this
        page could read, so check your wallet or{' '}
        <Link href="/bulls?filter=mine" className="underline hover:text-bull-gold-hover">
          browse your herd
        </Link>
        .
      </p>
    );
  }

  return (
    <MintedReveal
      minted={minted}
      txLink={txLink}
      revealFailed={revealFailed}
      onMintAnother={onMintAnother}
      isPen={isPen}
    />
  );
}

/**
 * Fefers' `SuccessBlock`, ported: the headline, then a GRID of cards for a
 * batch or one roomy panel for a single mint, then the tx link, then the row
 * of onward buttons.
 *
 * ⚠ NO NEW ART PATH AND NO SECOND CARD. `BullCard` is the same component
 * `/bulls` renders, which is itself a port of fefers' `OutlawCard`, so a bull
 * looks identical here, in browse and in the duel picker. Tier, name, sprite
 * and weapon come from the chain's own rarity shuffle via `getBull`
 * (`DECISIONS.md §27`); rating, record and the six stats are contract reads.
 */
function MintedReveal({
  minted,
  txLink,
  revealFailed,
  onMintAnother,
  isPen,
}: {
  minted: readonly MintedBull[];
  txLink: React.ReactNode;
  revealFailed: boolean;
  onMintAnother: () => void;
  isPen: boolean;
}) {
  const single = minted.length === 1 ? minted[0]! : null;

  return (
    <div className="mt-6 rounded border border-bull-gold/40 bg-bull-panel p-4">
      <MintSteps phase="success" isPen={isPen} />
      {/* ⚠ "DEALT" UNDER THE PEN, "MINTED" WITHOUT IT, AND THE WORD IS THE
          PAYOFF. The whole reason the buyer waited an extra transaction is that
          nobody could choose which bull this would be — so the sentence that
          lands should be the one about the draw, not the one about a mint they
          already know happened a minute ago. */}
      <p className="bull-header mt-2 text-bull-gold">
        {single
          ? isPen
            ? `you drew bull #${single.id}. he is yours.`
            : `bull #${single.id} minted. he is yours.`
          : isPen
            ? `you drew ${minted.length}. all yours.`
            : `${minted.length} minted. all yours.`}
      </p>

      {single ? (
        <SingleReveal minted={single} />
      ) : (
        <div className="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5">
          {minted.map((m) => (
            <BullCardLink key={m.id} id={m.id} facts={factsOf(m)} />
          ))}
        </div>
      )}

      {revealFailed && (
        <p className="mt-3 text-[11px] text-bull-text-faint">
          couldn&apos;t read the rating and record off the chain just now, so those lines are
          blank rather than guessed. the bulls are minted either way, and their own pages will
          carry the numbers once the rpc answers.
        </p>
      )}

      {/* ⚠ THIS USED TO SAY NOTHING ABOUT ARENA ENTRY, because `Yards` was not
          wired and asserting either "nothing to enter" or "you must enter them"
          would have been a claim this file could not back. It is wired now, and
          the honest line is the second one: `Yards.sol` defaults every bull
          OUT, a fresh mint included, and `Duel` reverts `BullNotInYards` on
          anything that has not been sent in. Saying so here is what stops a new
          holder discovering it as a failed transaction. */}
      <p className="mt-4 text-sm text-bull-text-dim">
        {single ? 'he is' : 'they are'} yours, and not fighting yet. {PIT.defaultOut}
      </p>

      <div className="mt-3 flex flex-wrap items-center gap-3">
        <Link href="/duel" className="bull-btn bull-btn-pulse">
          send {single ? 'him' : 'them'} into {PIT.label} ⚔️
        </Link>
        {single && (
          <Link
            href={`/bull/${single.id}`}
            className="rounded-full border border-bull-border px-3 py-1.5 text-xs font-medium text-bull-text-dim hover:border-bull-gold hover:text-bull-gold"
          >
            full stats
          </Link>
        )}
        <Link
          href="/bulls?filter=mine"
          className="rounded-full border border-bull-border px-3 py-1.5 text-xs font-medium text-bull-text-dim hover:border-bull-gold hover:text-bull-gold"
        >
          my herd
        </Link>
        <Link
          href="/bulls"
          className="rounded-full border border-bull-border px-3 py-1.5 text-xs font-medium text-bull-text-dim hover:border-bull-gold hover:text-bull-gold"
        >
          browse all
        </Link>
        <button
          type="button"
          onClick={onMintAnother}
          className="rounded-full border border-bull-border px-3 py-1.5 text-xs font-medium text-bull-text-dim hover:border-bull-gold hover:text-bull-gold"
        >
          mint another
        </button>
        {txLink}
      </div>
    </div>
  );
}

function factsOf(m: MintedBull): BullFacts {
  return {
    name: m.bull?.name,
    elo: m.bull?.elo,
    wins: m.bull?.wins,
    losses: m.bull?.losses,
    ties: m.bull?.ties,
    isDead: m.bull?.isDead,
  };
}

/**
 * One bull, room to breathe — fefers' `SingleMintPanel`: the portrait on the
 * left, and on the right the rating, the record, the weapon with its damage
 * and speed, and the six stats as chips.
 */
function SingleReveal({ minted }: { minted: MintedBull }) {
  const b = minted.bull;
  const w = minted.weapon;
  return (
    <div className="mt-3 grid gap-5 sm:grid-cols-[minmax(0,14rem)_1fr] sm:items-start">
      <Link
        href={`/bull/${minted.id}`}
        className="bull-card mx-auto block w-full max-w-[14rem] rounded border border-bull-border p-3 transition hover:border-bull-gold sm:mx-0"
      >
        <BullCard id={minted.id} facts={factsOf(minted)} scale={4} />
      </Link>
      <div>
        <dl className="grid grid-cols-2 gap-x-6 gap-y-3 text-sm">
          <div>
            <dt className="font-mono text-[10px] uppercase tracking-wide text-bull-text-faint">
              rating
            </dt>
            <dd className="mt-0.5 font-mono">{b ? b.elo : '—'}</dd>
          </div>
          <div>
            <dt className="font-mono text-[10px] uppercase tracking-wide text-bull-text-faint">
              record
            </dt>
            <dd className="mt-0.5 font-mono">
              {b ? `${b.wins}w / ${b.losses}l / ${b.ties}t` : '—'}
            </dd>
          </div>
          <div className="col-span-2">
            <dt className="font-mono text-[10px] uppercase tracking-wide text-bull-text-faint">
              weapon
            </dt>
            <dd className="mt-0.5">
              {w ? (
                <>
                  <span className="text-bull-gold">{w.name.toLowerCase()}</span>{' '}
                  <span className="font-mono text-xs text-bull-text-faint">
                    dmg {w.damageMin}–{w.damageMax} · spd {w.speed}
                  </span>
                </>
              ) : (
                '—'
              )}
            </dd>
          </div>
        </dl>
        <div className="mt-4 grid grid-cols-6 gap-1 text-center">
          {(
            [
              ['str', b?.strength],
              ['dex', b?.dexterity],
              ['con', b?.constitution],
              ['int', b?.intelligence],
              ['wis', b?.wisdom],
              ['cha', b?.charisma],
            ] as const
          ).map(([label, value]) => (
            <div key={label} className="rounded border border-bull-border px-1 py-1">
              <p className="font-mono text-[9px] uppercase text-bull-text-faint">{label}</p>
              <p className="font-mono text-sm text-bull-text">{value ?? '—'}</p>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
