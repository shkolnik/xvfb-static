## Summary

## Verification

- [ ] Build the affected variant(s) on native x86_64 and aarch64 runners
- [ ] Run the Alpine boot smoke test against each affected packaged archive
- [ ] For GLX changes, run the packaged llvmpipe render/readback test on both architectures
- [ ] Confirm `test/smoke.sh` passes its static-link, archive-shape, license, and manifest-inventory checks
- [ ] Check closure coverage and packaged license texts if dependencies changed
- [ ] Update README, AGENTS.md, notices, and release notes when their claims change
