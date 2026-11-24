import { CappedListing } from '@/types'

// L15: "showing N of M" — never silent truncation. The shared listing-cap
// caption (I16's F10 fix, judge Finding 10: a shared component lives in
// components/, not inside a page file). The one legacy consumer outside the
// I17 touch set (pages/Costs/Index.tsx) imports through the page-file
// re-export Dashboard keeps; new surfaces import from here directly.
export default function ShowingOf({ listing }: { listing?: CappedListing<unknown> }) {
  if (!listing || listing.requested <= listing.cap) return null
  return (
    <p className="text-xs text-muted-foreground" data-testid="showing-of">
      showing {listing.rows.length} of {listing.requested}
    </p>
  )
}
