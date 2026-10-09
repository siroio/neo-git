;;; install-compare-magit.el --- Isolated benchmark dependency setup -*- lexical-binding: t; -*-
;; Explicit opt-in: emacs -Q --batch -l benchmarks/install-compare-magit.el
(require 'package)
(setq package-user-dir (expand-file-name "neo-git-compare-elpa" temporary-file-directory)
      package-archives '(("melpa-stable" . "https://stable.melpa.org/packages/"))
      custom-file (expand-file-name "neo-git-compare-custom.el" temporary-file-directory)
      package-selected-packages nil)
(package-initialize)
(package-refresh-contents)
(package-install 'magit)
(princ (format "MAGIT_COMPARE_PACKAGES=%s\n" package-user-dir))
