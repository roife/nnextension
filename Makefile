EMACS ?= emacs
URL ?= https://meta.discourse.org

ELISP := nnextension-core.el nndiscourse.el nnhackernews.el nnextension.el
TESTS := test/nnextension-core-test.el test/nndiscourse-test.el \
	 test/nnhackernews-test.el

.PHONY: check compile test checkdoc package-lint smoke \
	smoke-discourse smoke-hackernews clean

check: compile test checkdoc

compile:
	$(EMACS) -Q --batch -L . -f batch-byte-compile $(ELISP)

test:
	$(EMACS) -Q --batch -L . -L test \
	  $(foreach file,$(TESTS),-l $(file)) \
	  -f ert-run-tests-batch-and-exit

checkdoc:
	$(EMACS) -Q --batch -L . \
	  --eval "(progn (require 'checkdoc) \
	    (dolist (file '(\"nnextension-core.el\" \"nndiscourse.el\" \
	                    \"nnhackernews.el\" \"nnextension.el\")) \
	      (checkdoc-file file)))"

package-lint:
	$(EMACS) -Q --batch -L . \
	  --eval "(progn (require 'package-lint) \
	    (setq package-lint-emacs-head-version '(32 0)) \
	    (dolist (file '(\"nnextension-core.el\" \"nndiscourse.el\" \
	                    \"nnhackernews.el\" \"nnextension.el\")) \
	      (package-lint-batch-and-exit file)))"

smoke: smoke-discourse smoke-hackernews

smoke-discourse:
	$(EMACS) -Q --batch -L . -L tools -l tools/nnextension-smoke.el \
	  --eval "(nnextension-smoke-discourse \"$(URL)\")"

smoke-hackernews:
	$(EMACS) -Q --batch -L . -L tools -l tools/nnextension-smoke.el \
	  --eval "(nnextension-smoke-hackernews)"

clean:
	$(RM) $(ELISP:.el=.elc) test/*.elc tools/*.elc
