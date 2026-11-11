# MacShot source import

Authorized by Derek on November 6, 2026. The local import uses the approved squash-subtree strategy. No remote repository or publication is authorized by this action.

## Source and filtering

- Upstream: https://github.com/sw33tLie/macshot
- Release: v4.4.0
- Exact upstream commit: `6370d0d23da3f5f73bc8074624a424a7102fcfa6`
- Destination: `apps/macos/`
- Native source, shared Xcode project, tests, upstream license, documentation, and instructions retain their upstream paths and bytes.
- `website/` and `assets/` are excluded: they contain MacShot marketing pages, screenshots of third-party sites, and MacShot-specific distribution artwork. They aren't PressShot source or approved PressShot assets.
- `macshot.xcodeproj/xcuserdata/` is excluded: upstream tracked one per-user scheme-order file; machine-local IDE state must not enter PressShot commits.

The repeatable filter lives in `scripts/prepare-macshot-import.py`. It produces a parentless source snapshot with the original commit recorded in its message, without altering the upstream checkout. Subtree squashes use that prepared commit. This prevents excluded paths entering PressShot history, rather than deleting them in a later commit.

On updates, fetch the real upstream revision, review its diff and provenance, rerun this filter, and subtree-merge the new prepared snapshot with `--squash` in a review branch. Preserve the original/prepared revision mapping. Don't run a direct unfiltered subtree pull. Audit newly introduced paths every time. Never push fetched upstream refs or tags as part of publishing PressShot.

## Upstream instruction reconciliation

MacShot's AGENTS.md delegates to CLAUDE.md. Its AppKit architecture, coordinate rules, streaming uploads, durable originals, concurrency, and test guidance apply to inherited source. PressShot's root AGENTS.md and PLAN.md govern product behavior, interfaces, and release authority.

In particular, upstream's screenshot clipboard image-only rule describes MacShot. PressShot's agreed successful-primary-upload link behavior takes precedence when that feature is implemented. Preserve useful local image-copy actions without silently replacing the agreed clipboard link. MacShot's offline variant and website/release maintenance aren't a commitment to ship those features in PressShot. Workflow files inside the subtree are retained as upstream source and don't execute as root GitHub Actions workflows.

## Licenses and assets

The original GPLv3 LICENSE is retained in the subtree and copied unchanged to the root. Existing credit remains in upstream source. Root THIRD_PARTY_NOTICES.md records provenance, dependency pins, and bundled notice texts. No BetterShot/Cap code was added separately. Source/comment searches found no explicit BetterShot/Cap provenance reference; that doesn't prove every historical file's provenance.

Visually reviewed upstream PNG inventory. Excluded public-webpage marketing captures. Retained native app icons, vector logo/status icon, and the generic macOS permission-guide image as inherited app resources, with upstream attribution. They are baseline resources, not approved PressShot branding. No user captures, credentials, runtime directories, compiled products, or private test output are part of the imported snapshot.

The dependency lock pins Sparkle 2.9.0, Swift-WebP 0.5.0, and libwebp-Xcode 1.5.0. Exact notices inspected are in docs/licenses/. The libwebp wrapper has no standalone license file in its pinned tree; the contained codec supplies COPYING and PATENTS. Its wrapper packaging provenance remains a release-review item. Dependency source/binaries aren't vendored into this repository by this import.

## Execution boundary

This import retains the upstream app identity and update feed for byte-level comparison. Don't run or distribute it as PressShot. A separate, reviewed change must set PressShot identity, disable MacShot updating, and handle provider application registration before native runtime checks. Interface implementation follows Derek's approval of review mockups.

## Indexed-source scan review

The targeted redacted scan found six candidates in the prepared source: one workflow URL uses an environment-variable placeholder; one AWS key is an input placeholder in settings; four are explicit AWS-key strings in auto-redaction tests. Inspected their source context and classified all six as templates/synthetic fixtures, not credentials. No forbidden path remained in the prepared tree. The scaffold scan found no candidates. This targeted check isn't a full-history or dedicated secret-scanner certification; run a dedicated scan and review before any first push.

## Import result

Prepared source commit: `0cddb50f46f841b4b56f080e8a1338ba42324347`. Prepared/imported tree: `08813ea64702fc06ea8c0c657047c2b02dde7ee6`. Local subtree merge: `502ff97`, with its separate squash commit `a77884c`. The imported 351 paths match the prepared tree exactly. The imported normal-variant Release build passed for arm64 and x86_64. The byte-identical native baseline had already passed 921 headless tests; they weren't repeated for path-only/source-packaging changes.

Configured only a local `macshot-upstream` remote, with a disabled push URL. No origin, remote repository creation, push, tag publication, or deployment occurred.
