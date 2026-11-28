# Windows service probe sources

The judgments, registry and response helpers in `probe_service_rules.go`,
`probe_service_check.go` and `probe_region.go` derive from the Flux6 Android
source at repository revision
`971a0fe` (FlClash-derived, GPL-3.0; see the repository LICENSE and
`apps/android/LICENSE`). The Windows files replace the package name and
`metacubex/http` with the standard library; judgments and region mapping are
unchanged. `probe_transport.go` supplies the Windows helper transport, using
the active core's mixed listener and never a direct fallback. Android files
are unchanged. Reconcile these recorded sources when updating the judgments.

- `apps/android/core/service_check.go`: `d955596a7b247510754415f77e250ee53af23c88216357695f4d0998044f9ed0` (LF-normalized SHA-256)
- `apps/android/core/service_rules.go`: `e22e4ca4692c2c8c7fcd42ac69b57c77841449b0eabc17b84f148a3de4612e4d` (LF-normalized SHA-256)
- `apps/android/core/region.go`: `4463b32e6f0dd62e962bac7d99249006412b23cc2fc777b0c966f5a50010a1e2` (LF-normalized SHA-256)
