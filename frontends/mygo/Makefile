# The MyGo frontend (ADR 0012). Each target is the repo-level script, so
# `make -C frontends/mygo test` and `make test-mygo` give the same verdict.
.PHONY: tools test measure

tools:
	$(MAKE) -C ../.. install-zig install-go

test:
	../../scripts/test-mygo.sh

measure: test
	../../scripts/measure-mygo.sh
