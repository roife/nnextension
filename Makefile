EMACS ?= emacs
URL ?= https://meta.discourse.org

.PHONY: check compile test checkdoc package-lint smoke clean

check: compile test checkdoc

compile:
	$(EMACS) -Q --batch -L . -f batch-byte-compile nndiscourse.el

test:
	$(EMACS) -Q --batch -L . -L test \
	  -l test/nndiscourse-test.el \
	  -f ert-run-tests-batch-and-exit

checkdoc:
	$(EMACS) -Q --batch -L . \
	  --eval "(progn (require 'checkdoc) (checkdoc-file \"nndiscourse.el\"))"

package-lint:
	$(EMACS) -Q --batch -L . \
	  --eval "(progn (require 'package-lint) \
	    (setq package-lint-emacs-head-version '(32 0)) \
	    (package-lint-batch-and-exit))" \
	  nndiscourse.el

smoke:
	$(EMACS) -Q --batch -L . -l tools/smoke.el --eval \
	  "(nndiscourse-smoke-test \"$(URL)\")"

clean:
	$(RM) nndiscourse.elc test/*.elc tools/*.elc
