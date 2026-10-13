# eventplanner

## First run

- DNS for `DOMAIN`, `DOMAIN_CONVEX`, `DOMAIN_CONVEX_SITE`, `DOMAIN_DASHBOARD`.
- authentik: create the provider from `./service.sh authentik`, with a `groups` scope mapping
  (`return {"groups": [g.name for g in request.user.ak_groups.all()]}`) and the admin group.
  Fill `PUBLIC_AUTHENTIK_ISSUER` and `PUBLIC_AUTHENTIK_APPLICATION_ID`.
- Fill `CALDAV_PASSWORD`.
- `./service.sh up` generates `CONVEX_SELF_HOSTED_ADMIN_KEY` into `.env`.
- Dashboard login: `./service.sh admin-key`.

## Quirks

- The admin key belongs to `volumes/convex`. If you restore one without the other, empty the
  key and run `up`.
