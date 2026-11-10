# Flux6 website design QA — 2026-11-10

final result: passed

## Source and implementation

- Source: https://chen08209.github.io/FlClash/zh/ ; revision `be84736605527034689c95bf27828ff27d912c5e`.
- Implementation: local `http://127.0.0.1:4173/`, built from this directory.
- Source screenshots: `build/site-qa/reference/freev6-source-desktop-hero.png`, `freev6-source-mobile-hero.png`, `freev6-source-desktop-download.png`, `freev6-source-mobile-download.png`, `freev6-source-desktop.png`.
- Implementation screenshots: `build/site-qa/desktop-hero.png`, `mobile-hero.png`, `desktop-download.png`, `mobile-download.png`, `desktop-full.png`, `mobile-full.png`, `desktop-dark-en.png`, `mobile-dark-en-motion.png`.
- Combined comparison: `build/site-qa/comparison.png` and `comparison.html`. Full-page and mobile source/implementation captures were also opened together. Paths are relative to the repository root and remain in the ignored local QA directory.
- Hero comparison: desktop CSS/pixel size 1440 × 1000, mobile CSS/pixel size 390 × 844, DPR 1 for source and implementation. No density conversion. Both images are equally scaled in the combined sheet; originals were inspected for readable details.
- States: Chinese/light/macOS on desktop; Chinese/light/Android on mobile. Focused download sections use the same desktop width and selected platform. English/dark and ordinary-motion states received additional implementation checks.

## Findings and comparison history

No actionable P0/P1/P2 findings remain.

1. P2: the platform reel retained its previous pixel width after viewport resizing, clipping Android. The first attempt added intrinsic-width flex items, but recapture still showed clipping. Changed measured button width to font-relative `em` units. The final `mobile-hero.png`, compared alongside the source mobile capture, shows the full label after resizing from 320 to 390 pixels.
2. The upstream history has many releases; Flux6 has one verified public release. The shorter page is intentional. Upstream release history, star counts and unshipped platforms are not presented as Flux6 data.
3. The repository cat icon and real screenshots intentionally replace the upstream logo and device mockup. Images retain native proportions. Both themes use the same real light-mode application captures.
4. The mobile Flux6 wordmark is larger to reflect the user's requested simple, prominent English branding. Platform line, controls, gutters and information order retain the source hierarchy.
5. The name-transition note adds space above download tabs, explaining the existing FreeV6 installer and Homebrew names. This is intentional product information.

## Required fidelity surfaces

| Surface | Result |
| --- | --- |
| Fonts and typography | Original system font stacks, weights, line heights and hierarchy retained, with intentional mobile brand emphasis. Final platform labels are not clipped. |
| Spacing and layout | Original 1120px content measure, navigation, two-column download rail, feature grid, radii and section rhythm retained. Focused download comparison inspected in the combined sheet. |
| Colors and tokens | Original warm-gray light palette, plum accent and dark palette retained in unchanged upstream CSS. Theme selection and persistence verified. |
| Image quality | Local repository cat SVG, macOS PNG and Android JPEG; natural proportions and no hotlinked upstream product imagery. Existing upstream UI SVG icons retained. |
| Copy and content | Flux6 branding, accurate supported systems, verified v0.1.0 download metadata, bilingual copy and changelogs. FreeV6 remains where it truthfully describes current installers/screenshots. |

## Interaction and browser checks

`build/site-qa/checks.json` records browser results. Verified widths 320, 390, 768, 1024 and 1440px: no horizontal document overflow or failed images. Tested macOS/Android tabs, arrow-key navigation, hero platform reel, exact release download URLs, SHA-256 copying, Homebrew command copying, language switching/persistence, theme switching/persistence, `/` search focus, match/no-results search, Escape clearing, and JavaScript-disabled installation links and release notes. Normal animation mode also passed mobile theme/language/reel checks. Browser console and page errors: none.

Build, JavaScript syntax, local asset/link checks, repository maintenance checks, nine maintenance tests, icon/publisher checks and existing Web module checks passed.

## Verification limits

CUA connections timed out. The user explicitly authorized Playwright; checks used isolated headless Chrome. This was website QA only: no client, proxy/VPN or system service was started or changed, and browser tests did not download or run installers. Native names, package IDs, signing identities, runtime directories and published assets remain unchanged. No remote publishing or deployment occurred.

## Implementation checklist

- [x] Inspect desktop/mobile source and interactive states.
- [x] Preserve upstream license, revision and local patch record.
- [x] Adapt to Flux6, real screenshots and verified releases.
- [x] Fix and recapture mobile title clipping.
- [x] Compare source and implementation hero/download views together.
- [x] Verify interactions, responsive layouts, languages and themes.

Follow-up polish: none required for this handoff.
