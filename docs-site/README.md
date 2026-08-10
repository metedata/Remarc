# Remarc Docs

End-user documentation for [Remarc](https://remarc.app), built with [Astro Starlight](https://starlight.astro.build). Lives at [docs.remarc.app](https://docs.remarc.app).

## Local development

```sh
cd docs-site
npm install
npm run dev       # http://localhost:4321
```

## Build

```sh
npm run build     # output in dist/, includes Pagefind search index
npm run preview   # serve the production build locally
```

The build fails on broken internal links (`starlight-links-validator`).

## Writing pages

- Content lives in `src/content/docs/<section>/<page>.md`. The sidebar is explicit in `astro.config.mjs` - add new pages there too.
- Frontmatter needs `title` and `description`. No H1 in the body.
- Copy rules: no em dashes anywhere (user-facing text), shortcuts written as `Ctrl+Option+R`, internal links are absolute with trailing slash (`/getting-started/permissions/`).
- Brand accent colors are in `src/styles/custom.css` and come from `docs/brand-kit.md` at the repo root.

## Deployment (Cloudflare Workers, static assets)

The site deploys as an assets-only Worker named `remarc-docs` (see `wrangler.jsonc`), the same model as the main `remarc` worker that serves remarc.app. Cloudflare recommends Workers over Pages for new projects.

Manual deploy:

```sh
npm run build && npx wrangler deploy
```

The first deploy creates the Worker and the `docs.remarc.app` custom domain (DNS record included, since the zone is on Cloudflare).

Automatic deploys are handled by Workers Builds (Git integration, configured in the dashboard: Worker > Settings > Build):

- Repository: `metedata/Remarc`, root directory `/docs-site`
- Build command: `npm run build`
- Deploy command: `npx wrangler deploy`

Every push to `main` that touches `docs-site/` then rebuilds and deploys the docs.
