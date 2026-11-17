;;; check-vcs-package.el --- Check full multi-file installation -*- lexical-binding: t; -*-
;; emacs -Q --batch -l check-vcs-package.el
(require 'package)
(require 'cl-lib)

(let* ((source (file-name-directory load-file-name))
       (directory (make-temp-file "neo-vcs-package-" t))
       (user-emacs-directory (file-name-as-directory directory))
       (package-user-dir (expand-file-name "elpa/" directory))
       (package-archives nil)
       (name "neo-git-0.4")
       (staging (expand-file-name name directory))
       (archive (expand-file-name (concat name ".tar") directory))
       (libraries '("neo-git" "neo-vcs" "neo-vcs-jj" "neo-vcs-hg" "neo-vcs-svn" "neo-vcs-p4")))
  (unwind-protect
      (progn
        (make-directory staging)
        (dolist (library libraries)
          (copy-file (expand-file-name (concat library ".el") source)
                     (expand-file-name (concat library ".el") staging)))
        (with-temp-file (expand-file-name "neo-git-pkg.el" staging)
          (insert "(define-package \"neo-git\" \"0.4\" \"Asynchronous native VCS UI\" '((emacs \"29.1\")))\n"))
        (let ((default-directory directory))
          (cl-assert (eq 0 (call-process "tar" nil nil nil "-cf" archive name))))
        ;; The source checkout must not hide missing files in the package.
        (setq load-path (cl-remove-if
                         (lambda (path) (and path (equal (file-truename path) (file-truename source))))
                         load-path))
        (package-initialize)
        (package-install-file archive)
        (cl-assert (package-installed-p 'neo-git '(0 4)))
        ;; Compilation loads backend dependencies in this process.  Check
        ;; startup/autoloads in a fresh Emacs using only the installed files.
        (let ((probe (expand-file-name "startup.el" directory)))
          (with-temp-file probe
            (insert ";;; -*- lexical-binding: t; -*-\n")
            (prin1 `(progn
                      (setq user-emacs-directory ,user-emacs-directory
                            package-user-dir ,package-user-dir
                            native-comp-jit-compilation nil
                            native-comp-deferred-compilation nil)
                      (require 'package)
                      (package-initialize)
                      (cl-assert (autoloadp (symbol-function 'neo-git-status)))
                      (cl-assert (autoloadp (symbol-function 'neo-vcs-status)))
                      (dolist (library ',libraries)
                        (require (intern library))
                        (cl-assert (file-in-directory-p (locate-library library) package-user-dir))))
                   (current-buffer)))
          (with-temp-buffer
            (unless (eq 0 (call-process (expand-file-name invocation-name invocation-directory)
                                       nil t nil "-Q" "--batch" "-l" probe))
              (error "Installed startup failed: %s" (buffer-string)))))
        (dolist (library libraries)
          (require (intern library))
          (cl-assert (file-in-directory-p (locate-library library) package-user-dir)))
        (cl-assert (= (length neo-vcs--backends) 4))
        (dolist (backend '(jj hg svn p4))
          (cl-assert (functionp (plist-get (neo-vcs--backend backend) :request))))
        (princ "NEO_VCS_PACKAGE=PASS\n"))
    (delete-directory directory t)))
;;; check-vcs-package.el ends here
