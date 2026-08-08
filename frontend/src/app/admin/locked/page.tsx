/**
 * /admin/locked — what an unauthenticated visitor to /admin actually gets.
 *
 * `src/middleware.ts` REWRITES /admin here when there's no valid session
 * cookie, so the URL bar still reads /admin but the response is this page. That
 * is the whole point of it being a separate route: a route boundary is also a
 * bundle boundary, so a stranger's browser downloads this page's chunks and
 * never receives a byte of the cockpit's client code.
 *
 * Reaching this URL directly is harmless: it's a sign-in button and a flat
 * panel, it holds no data and grants nothing on its own.
 */
import type { Metadata } from 'next';
import { AdminSignIn } from '@/components/admin/AdminGate';

export const dynamic = 'force-dynamic';

export const metadata: Metadata = {
  title: 'nothing here',
  robots: { index: false, follow: false, nocache: true },
};

export default function AdminLockedPage() {
  return <AdminSignIn />;
}
