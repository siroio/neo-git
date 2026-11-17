;;; check-vcs-integration.el --- Entry points and backend contracts -*- lexical-binding: t; -*-
(require 'ert)
(require 'neo-vcs)

(ert-deftest neo-vcs-native-actions-preserve-common-keys ()
  (dolist (name '(jj hg svn p4))
    (let ((common (copy-keymap neo-vcs-mode-map)) seen)
      ;; Inherited tabulated-list aliases may be repurposed by native actions.
      (set-keymap-parent common nil)
      (dolist (action (plist-get (neo-vcs--backend name) :actions))
        (let ((key (plist-get action :key)))
          (when key
            (should-not (lookup-key common (kbd key)))
            (should-not (member key seen))
            (push key seen)))))))

(ert-deftest neo-vcs-colocated-jj-allows-explicit-git ()
  (let* ((root (file-name-as-directory (make-temp-file "neo-vcs-colocated-" t)))
         (default-directory root) opened)
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".jj" root))
          (make-directory (expand-file-name ".git" root))
          (cl-letf (((symbol-function 'neo-vcs--execute)
                     (lambda (context &rest _) (setq opened (plist-get context :backend))))
                    ((symbol-function 'neo-vcs--request) (lambda (&rest _) nil))
                    ((symbol-function 'neo-git--status-git) (lambda () (setq opened 'git))))
            (neo-git-status)
            (should (eq opened 'jj))
            (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "git")))
              (neo-git-status t))
            (should (eq opened 'git))))
      (delete-directory root t))))

(provide 'check-vcs-integration)
