# Third-party notices

## MacShot

PressShot's native app source is derived from [MacShot by sw33tLie](https://github.com/sw33tLie/macshot), release v4.4.0, upstream commit `6370d0d23da3f5f73bc8074624a424a7102fcfa6`.

The GPLv3 license text is preserved unchanged at root LICENSE and apps/macos/LICENSE. Preserve upstream authorship and notices. Add visible MacShot credit to PressShot's About interface when that approved interface is implemented. PressShot isn't an official MacShot release.

The source-only import excludes the upstream marketing website/artwork and per-user Xcode state; see docs/architecture/macshot-import-record.md. No BetterShot/Cap-derived source was separately introduced.

## Locked native dependencies

| Dependency | Locked version | Locked revision | Notice |
| --- | --- | --- | --- |
| Sparkle | 2.9.0 | `21d8df80440b1ca3b65fa82e40782f1e5a9e6ba2` | docs/licenses/Sparkle-LICENSE.txt, including embedded notices |
| Swift-WebP | 0.5.0 | `3f5895711566ee862e7cff7694867c6f77adf452` | docs/licenses/Swift-WebP-LICENSE.txt (MIT) |
| libwebp-Xcode | 1.5.0 | `0d60654eeefd5d7d2bef3835804892c40225e8b2` | Wrapper licensing review remains open; codec notices below |
| libwebp submodule | pinned by wrapper | `a4d7a715337ded4451fec90ff8ce79728e04126c` | docs/licenses/libwebp-COPYING.txt and libwebp-PATENTS.txt |

Dependencies are resolved externally using the upstream lockfile. No dependency installation or binary archive belongs in source commits. Before distribution, review the actual packaged components and include their full required notices. A source import isn't a completed binary-distribution audit.

## Fraunces wordmark

The approved PressShot wordmark is outlined from Fraunces by Undercase Type. The font source is distributed under the SIL Open Font License 1.1; its exact notice is preserved at `docs/licenses/Fraunces-OFL.txt` and in the Keepsake brand package. The app embeds outlined PDF artwork, not a runtime font installation.
