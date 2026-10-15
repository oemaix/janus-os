# Janet tooling

Specified in docs/adr/0008-janet-for-matchers-and-tooling.md and
docs/adr/0020-keep-janet-not-go.md.

`janus.janet` is the normalizer, the matchers, and the sing-box renderer.
The same file runs at image build and on the router. Do not start this
in Go.

`hmi.janet` is the panel model in docs/15.

`web.janet` is the maintenance page in docs/20.
