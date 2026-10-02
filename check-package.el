;;; check-package.el --- Check standalone installation -*- lexical-binding: t; -*-
;; emacs -Q --batch -l check-package.el
(require 'package)
(require 'cl-lib)

(let* ((source (expand-file-name "neo-git.el" (file-name-directory load-file-name)))
       (directory (make-temp-file "neo-git-package-" t))
       (user-emacs-directory (file-name-as-directory directory))
       (package-user-dir (expand-file-name "elpa/" directory))
       (package-archives nil))
  (unwind-protect
      (progn
        (package-initialize)
        (package-install-file source)
        (cl-assert (package-installed-p 'neo-git '(0 2)))
        (cl-assert (autoloadp (symbol-function 'neo-git-status)))
        (cl-assert (not (boundp 'neo-leader-map)))
        (require 'neo-git)
        (cl-assert (file-in-directory-p (locate-library "neo-git") directory))
        (cl-assert (not (featurep 'evil)))
        (with-temp-buffer
          (neo-git-mode)
          (cl-assert (derived-mode-p 'neo-git-mode))
          (cl-assert (eq (key-binding (kbd "SPC")) #'neo-git-stage-toggle)))
        (princ "NEO_GIT_PACKAGE=PASS\n"))
    (delete-directory directory t)))
;;; check-package.el ends here
