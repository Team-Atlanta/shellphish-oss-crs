
- The `src` sub dir contains all md files as content
- `src/SUMMARY.md` should only contain table of content. Otherwise, `mdbook` will raise error
- The file architecture under `src` is organized based on the `src/whitepaper` content. The `src/whitepaper` dir is not part of the markdown book but the internal white paper written by the repo developer. However, in their whitepaper, all components are written with high-level design without low-level impl overview. Therefore, our `notes/src` markdown book is complementary. You could find md files for each section or subsection (from section 4 to section 9 in whitepaper) in `notes/src`.
