# The Blue Moon Store

Independent ecommerce website for The Blue Moon.

This application uses the existing Supabase project for:

- PostgreSQL database
- Supabase Auth
- Supabase Storage

The POS application and this ecommerce application are separate applications
with separate frontends and backends while sharing the same Supabase data.

## Render availability check

The GitHub Actions workflow at `.github/workflows/keep-render-awake.yml`
requests the deployed `/api/health` endpoint every 10 minutes to reduce
Render's free-instance idle spin-down. GitHub Actions scheduling can be
delayed or paused, so this is not an uptime guarantee. For guaranteed
always-on service, use a Render plan without idle spin-down.

## Route-based checkout delivery

Checkout uses Leaflet with OpenStreetMap tiles for map pin selection. Address
search and reverse geocoding use Nominatim, and the backend calculates driving
distance through OSRM, choosing the shortest route returned when alternatives
are available. Checkout requests browser location access when it opens; the
customer's browser controls permission, and customers can instead search for
an address or adjust the pin using the "Set location on map" control. OSRM uses
different road data and routing rules from Google Maps, so route distances may
still differ.
The checkout price is the admin-set base fare plus NPR 50 per route kilometer.
Free-delivery promotions continue to waive the delivery fee. Orders cannot be
placed until route pricing succeeds.

Configure these backend environment variables:

- `OSM_NOMINATIM_URL`: Nominatim service base URL; defaults to
  `https://nominatim.openstreetmap.org`.
- `OSM_ROUTING_URL`: OSRM service base URL; defaults to
  `https://router.project-osrm.org`.
- `STORE_CONTACT_EMAIL`: contact included with Nominatim requests.
- `STORE_ORIGIN_LATITUDE` and `STORE_ORIGIN_LONGITUDE`: private store coordinates.
  Do not put the origin in frontend code or expose it through an API response.

## Database migration order

For a **new database**, apply the numbered migrations in order through 011,
then apply these checkout migrations in this order:

1. `database/migrations/012_server_side_delivery_promotions.sql`
2. `database/migrations/012_create_store_order_fixed.sql`
3. `database/migrations/013_release_promo_on_order_cancel.sql`
4. `database/migrations/preview_store_checkout.sql`
5. `database/migrations/014_route_based_delivery.sql`
6. `database/migrations/015_order_delivery_location.sql`
7. `database/migrations/016_customer_phone_update.sql`

The two `012_` files define the same seven-argument checkout function; the
server-side promotions migration also drops the obsolete six-argument version.
The preview function embedded in `012_create_store_order_fixed.sql` is not
compatible with the current customer and product tables. Apply
`preview_store_checkout.sql` after the numbered checkout migrations and before
014 so it installs the compatible preview function required for route-priced
checkout. Apply the scripts in the listed order on a fresh database; do not
infer order from the shared numeric prefix.

On an **existing database**, do not replay the full migration history blindly.
Migrations 001–010 contain non-idempotent type/table/policy/constraint
operations, and migration 012 server-side promotions explicitly drops an old
checkout function signature. Migration 011 normalizes existing promotion
codes and creates a case-insensitive unique index, so existing codes that
become duplicates after normalization must be resolved first. Use Supabase
migration history to determine which scripts have already been applied, and
apply only missing migrations after checking their prerequisites.

Migrations 014–016 are designed to be rerunnable and do not intentionally drop
functions, tables, or stored data. Migration 014 validates its checkout and
preview prerequisites and creates separate route-priced RPCs, without replacing
the original RPCs. Migration 015 requires 014, adds nullable order coordinates
and a non-validating pair/range constraint, and saves coordinates atomically
with order creation. Migration 016 requires the `profiles` and `customers`
tables and synchronizes their phone values through a service-role-only RPC.
Conflicting existing objects cause an explicit error rather than being
silently replaced. The admin delivery setting is the base fare; the
per-kilometer rate is fixed at NPR 50. The admin order detail page provides an
"Open in Google Maps" link using the saved coordinates.

The public OSM-hosted Nominatim, tile, and OSRM services have usage policies,
rate limits, and no production availability guarantee. The application limits
Nominatim requests to one per second per backend process and searches only when
the customer submits a query. For production traffic, configure reliable
OSM-compatible hosted services or self-host them, and review their attribution
and usage requirements.
