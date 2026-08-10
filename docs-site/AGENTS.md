This is the end-user documentation site (Astro Starlight, deployed at docs.remarc.app). Everything under `src/content/docs/` is user-facing copy: the repo-wide no-em-dash rule applies to ALL of it. Shortcuts are written `Ctrl+Option+R`, internal links absolute with trailing slash. The sidebar is explicit in `astro.config.mjs` - new pages must be added there. See README.md for deployment.

## Development

When starting the dev server, use background mode:

```
astro dev --background
```

Manage the background server with `astro dev stop`, `astro dev status`, and `astro dev logs`.

## Documentation

Full documentation: https://docs.astro.build

Consult these guides before working on related tasks:

- [Adding pages, dynamic routes, or middleware](https://docs.astro.build/en/guides/routing/)
- [Working with Astro components](https://docs.astro.build/en/basics/astro-components/)
- [Using React, Vue, Svelte, or other framework components](https://docs.astro.build/en/guides/framework-components/)
- [Adding or managing content](https://docs.astro.build/en/guides/content-collections/)
- [Adding styles or using Tailwind](https://docs.astro.build/en/guides/styling/)
- [Supporting multiple languages](https://docs.astro.build/en/guides/internationalization/)
