;;; check-remote-delete.el --- Remote branch deletion checks -*- lexical-binding: t; -*-
(load (expand-file-name "neo-git.el" (file-name-directory load-file-name)) nil t)
(require 'ert)

(defun neo-git-remote-check-call (root &rest args)
  (with-temp-buffer
    (let ((status (apply #'process-file (neo-git--executable) nil t nil "-C" root args)))
      (cl-assert (zerop status) nil "Git %S: %s" args (buffer-string)))
    (string-trim (buffer-string))))

(defun neo-git-remote-check-wait (owner browser)
  (let ((deadline (+ (float-time) 15)))
    (while (and (< (float-time) deadline)
                (or (buffer-local-value 'neo-git--mutation owner)
                    (buffer-local-value 'neo-git--status-updating owner)
                    (buffer-local-value 'neo-git--browser-process browser)))
      (accept-process-output nil 0.05))
    (should-not (buffer-local-value 'neo-git--mutation owner))
    (should-not (buffer-local-value 'neo-git--status-updating owner))
    (should-not (buffer-local-value 'neo-git--browser-process browser))))

(ert-deftest neo-git-remote-delete-confirm-lease-and-refresh ()
  (let* ((base (make-temp-file "neo-git-remote-delete-" t))
         (root (file-name-as-directory (expand-file-name "work" base)))
         (remote (expand-file-name "remote.git" base))
         (default-directory temporary-file-directory)
         (owner (generate-new-buffer " *remote-delete-owner*"))
         (ref "refs/remotes/team/upstream/feature/topic")
         browser history old-oid)
    (unwind-protect
        (progn
          (make-directory root)
          (make-directory remote)
          (neo-git-remote-check-call remote "init" "--bare" "-q")
          (neo-git-remote-check-call root "init" "-q" "-b" "main")
          (neo-git-remote-check-call root "config" "user.name" "Check")
          (neo-git-remote-check-call root "config" "user.email" "check@example.invalid")
          (neo-git-remote-check-call root "config" "commit.gpgsign" "false")
          (neo-git-remote-check-call root "commit" "--allow-empty" "-qm" "baseline")
          (setq old-oid (neo-git-remote-check-call root "rev-parse" "HEAD"))
          (neo-git-remote-check-call root "branch" "feature/topic")
          (neo-git-remote-check-call root "remote" "add" "team/upstream" remote)
          (neo-git-remote-check-call root "push" "-q" "team/upstream" "feature/topic")
          (with-current-buffer owner
            (neo-git-mode)
            (setq neo-git-root root neo-git-state '(:branch "main")))
          (setq browser (neo-git--browser-buffer 'branches owner))
          (neo-git-remote-check-wait owner browser)
          (setq history (neo-git--browser-buffer 'history owner))
          (with-current-buffer history
            (setq neo-git--history-all t)
            (neo-git-browser-refresh))
          (neo-git-remote-check-wait owner history)
          (with-current-buffer history
            (should (string-match-p "team/upstream/feature/topic" (buffer-string))))
          (with-current-buffer browser
            (should (assoc ref tabulated-list-entries))
            (cl-letf (((symbol-function 'tabulated-list-get-id) (lambda () ref))
                      ((symbol-function 'yes-or-no-p)
                       (lambda (prompt)
                         (should (string-match-p "team/upstream" prompt))
                         (should (string-match-p "feature/topic" prompt))
                         nil)))
              (neo-git-browser-delete))
            (should-error
             (cl-letf (((symbol-function 'tabulated-list-get-id) (lambda () ref)))
               (neo-git-branch-force-delete)) :type 'user-error))
          (should (equal old-oid (neo-git-remote-check-call remote "rev-parse" "refs/heads/feature/topic")))
          (neo-git-remote-check-call root "symbolic-ref" "refs/remotes/team/upstream/HEAD" ref)
          (with-current-buffer browser
            (cl-letf (((symbol-function 'tabulated-list-get-id)
                       (lambda () "refs/remotes/team/upstream/HEAD")))
              (should-error (neo-git-browser-delete) :type 'user-error)))
          ;; Additional mappings could make this row name a different server branch.
          (neo-git-remote-check-call root "config" "--add" "remote.team/upstream.fetch"
                                     "+refs/heads/other:refs/remotes/team/upstream/feature/topic")
          (with-current-buffer browser
            (cl-letf (((symbol-function 'tabulated-list-get-id) (lambda () ref)))
              (should-error (neo-git-browser-delete) :type 'user-error)))
          (neo-git-remote-check-call root "config" "--replace-all" "remote.team/upstream.fetch"
                                     "+refs/heads/*:refs/remotes/team/upstream/*")
          ;; Another writer advances the server branch after our last fetch.
          (neo-git-remote-check-call root "commit" "--allow-empty" "-qm" "advance")
          (neo-git-remote-check-call root "push" "-q" "team/upstream" "HEAD:refs/heads/other")
          (neo-git-remote-check-call remote "update-ref" "refs/heads/feature/topic"
                                     (neo-git-remote-check-call root "rev-parse" "HEAD"))
          (with-current-buffer browser
            (cl-letf (((symbol-function 'tabulated-list-get-id) (lambda () ref))
                      ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
              (neo-git-browser-delete)))
          (neo-git-remote-check-wait owner browser)
          (should (buffer-local-value 'neo-git--last-error owner))
          (with-current-buffer browser (should (assoc ref tabulated-list-entries)))
          (should (equal (neo-git-remote-check-call root "rev-parse" "HEAD")
                         (neo-git-remote-check-call remote "rev-parse" "refs/heads/feature/topic")))
          (neo-git-remote-check-call root "fetch" "-q" "team/upstream")
          (with-current-buffer browser (neo-git-browser-refresh))
          (neo-git-remote-check-wait owner browser)
          (with-current-buffer browser
            (cl-letf (((symbol-function 'tabulated-list-get-id) (lambda () ref))
                      ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
              (neo-git-browser-delete)))
          (neo-git-remote-check-wait owner browser)
          (should-not (buffer-local-value 'neo-git--last-error owner))
          (neo-git-remote-check-wait owner history)
          (with-current-buffer history
            (should-not (string-match-p "team/upstream/feature/topic" (buffer-string))))
          (should (string-empty-p (neo-git-remote-check-call remote "for-each-ref" "refs/heads/feature/topic")))
          (with-current-buffer browser (should-not (assoc ref tabulated-list-entries)))
          (should (equal old-oid (neo-git-remote-check-call root "rev-parse" "refs/heads/feature/topic")))
          (should-not (string-empty-p (neo-git-remote-check-call remote "for-each-ref" "refs/heads/other"))))
      (dolist (buffer (list owner browser history))
        (when (buffer-live-p buffer) (kill-buffer buffer)))
      (delete-directory base t))))

(ert-run-tests-batch-and-exit)
