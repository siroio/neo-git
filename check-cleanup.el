;;; check-cleanup.el --- Session cleanup checks -*- lexical-binding: t; -*-
(load (expand-file-name "neo-git.el" (file-name-directory load-file-name)) nil t)
(require 'ert)

(defun neo-git-cleanup-check-process (&optional function)
  "Run a waiting child Emacs through the normal asynchronous runner."
  (let ((make-process-function (symbol-function 'make-process)))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest arguments)
                 (apply make-process-function
                        (plist-put arguments :command
                                   (list (expand-file-name invocation-name invocation-directory)
                                         "-Q" "--batch" "--eval"
                                         "(kill-emacs (string-to-number (read-string \"\")))"))))))
      (if function (funcall function)
        (neo-git--run default-directory '("status") #'ignore)))))

(defun neo-git-cleanup-check-wait (predicate)
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))

(defun neo-git-cleanup-check-finish (process &optional status)
  "Let PROCESS exit naturally, then wait for its completion callback."
  (process-send-string process (format "%s\n" (or status 0)))
  (neo-git-cleanup-check-wait
   (lambda () (plist-get (process-get process 'neo-git-log-entry) :finished)))
  (should (= (or status 0) (process-exit-status process))))

(ert-deftest neo-git-cleanup-session ()
  (dolist (action '(quit quit-narrow kill))
    (save-window-excursion
      (let* ((original (window-buffer (selected-window)))
             (owner (generate-new-buffer " *cleanup-status*"))
             (preview (generate-new-buffer " *cleanup-preview*"))
             (browser (generate-new-buffer " *cleanup-browser*"))
             (cached (generate-new-buffer " *cleanup-cache*"))
             (other (generate-new-buffer " *cleanup-other-session*"))
             processes outputs timers)
        (unwind-protect
            (progn
              (with-current-buffer owner
                (neo-git-mode)
                (setq neo-git--preview-buffer preview
                      neo-git--preview-cache (list (cons 'cached cached))
                      neo-git--window-config (unless (eq action 'quit-narrow)
                                               (current-window-configuration))
                      neo-git--refresh-timer (run-at-time 60 nil #'ignore))
                (neo-git--progress-begin)
                (setq timers (list neo-git--refresh-timer neo-git--progress-timer)))
              (with-current-buffer preview (setq-local neo-git--diff-owner owner))
              (with-current-buffer browser
                (neo-git-browser-mode)
                (setq neo-git--diff-owner owner))
              (with-current-buffer other (neo-git-mode))
              (dolist (buffer (list owner preview browser other))
                (with-current-buffer buffer
                  (let ((process (neo-git-cleanup-check-process)))
                    (push process processes)
                    (push (process-buffer process) outputs)
                    (push (process-get process 'neo-git-stderr-buffer) outputs))))
              ;; Keep another session's process out of the cleanup assertions.
              (let ((other-process (car processes)))
                (setq outputs (cddr outputs))
                (when (eq action 'quit-narrow) (switch-to-buffer preview))
                (switch-to-buffer owner)
                (if (eq action 'kill) (kill-buffer owner) (neo-git-quit))
                (should-not (buffer-live-p owner))
                (dolist (buffer (list preview browser cached))
                  (should-not (buffer-live-p buffer)))
                (dolist (process (cdr processes)) (should-not (process-live-p process)))
                (dolist (buffer outputs) (should-not (buffer-live-p buffer)))
                (dolist (timer timers) (should-not (memq timer timer-list)))
                (should (buffer-live-p original))
                (should (buffer-live-p other))
                (should (process-live-p other-process))
                (when (eq action 'quit) (should (eq (current-buffer) original)))))
          (dolist (buffer (list owner preview browser cached other))
            (when (buffer-live-p buffer) (kill-buffer buffer)))
          (dolist (process processes)
            (when (process-live-p process) (delete-process process))))))))

(ert-deftest neo-git-cleanup-browser-kill ()
  (let ((buffer (generate-new-buffer " *cleanup-browser*")) process out err)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (neo-git-browser-mode)
            (setq process (neo-git-cleanup-check-process)
                  out (process-buffer process)
                  err (process-get process 'neo-git-stderr-buffer)))
          (kill-buffer buffer)
          (should-not (process-live-p process))
          (should-not (buffer-live-p out))
          (should-not (buffer-live-p err)))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (when (process-live-p process) (delete-process process)))))

(ert-deftest neo-git-cleanup-pinned-browser-returns-to-list ()
  (save-window-excursion
    (let ((owner (generate-new-buffer " *cleanup-pinned-owner*"))
          (browser (generate-new-buffer " *cleanup-pinned-browser*")))
      (unwind-protect
          (progn
            (switch-to-buffer owner)
            (neo-git-mode)
            (setq neo-git--history-window (split-window-below))
            (set-window-buffer neo-git--history-window browser)
            (select-window neo-git--history-window)
            (neo-git-browser-mode)
            (setq neo-git--diff-owner owner)
            (neo-git-browser-quit)
            (should (eq (window-buffer (selected-window)) owner))
            (should (buffer-live-p browser)))
        (when (buffer-live-p owner) (kill-buffer owner))
        (when (buffer-live-p browser) (kill-buffer browser))))))

(ert-deftest neo-git-cleanup-mutation-does-not-restart-browsers ()
  (dolist (action '(quit kill))
    (dolist (status '(0 1))
      (save-window-excursion
        (let ((owner (generate-new-buffer " *cleanup-mutation*"))
              (browser (generate-new-buffer " *cleanup-mutation-browser*"))
              process out err)
          (unwind-protect
              (progn
                (with-current-buffer browser (setq-local neo-git--diff-owner owner))
                (switch-to-buffer owner)
                (neo-git-mode)
                (setq neo-git-root default-directory)
                (neo-git-cleanup-check-process (lambda () (neo-git--mutate '("fetch"))))
                (setq process neo-git--mutation-process out (process-buffer process)
                      err (process-get process 'neo-git-stderr-buffer))
                (cl-letf (((symbol-function 'neo-git--refresh-browsers)
                           (lambda (&rest _) (ert-fail "Refresh restarted during cleanup"))))
                  (if (eq action 'quit) (neo-git-quit) (kill-buffer owner))
                  (should (buffer-live-p owner))
                  (should (buffer-live-p browser))
                  (should (process-live-p process))
                  (should (buffer-live-p out))
                  (neo-git-cleanup-check-finish process status))
                (dolist (buffer (list owner browser out err))
                  (should-not (buffer-live-p buffer))))
            (when (process-live-p process) (delete-process process))
            (dolist (buffer (list owner browser))
              (when (buffer-live-p buffer) (kill-buffer buffer)))))))))

(ert-deftest neo-git-cleanup-waits-for-chained-operation ()
  (let ((owner (generate-new-buffer " *cleanup-chain*")) first second)
    (unwind-protect
        (progn
          (with-current-buffer owner
            (neo-git-mode)
            (setq neo-git--mutation t)
            (setq first
                  (neo-git-cleanup-check-process
                   (lambda ()
                     (neo-git--run
                      default-directory '("diff")
                      (lambda (&rest _)
                        (with-current-buffer owner
                          (setq second
                                (neo-git-cleanup-check-process
                                 (lambda ()
                                   (neo-git--run default-directory '("apply")
                                                 (lambda (&rest _)
                                                   (with-current-buffer owner
                                                     (setq neo-git--mutation nil)))))))
                          (neo-git--progress-set-process second)))))))
            (neo-git--progress-set-process first))
          (kill-buffer owner)
          (should (buffer-live-p owner))
          (neo-git-cleanup-check-finish first)
          (should (buffer-live-p owner))
          (should (process-live-p second))
          (neo-git-cleanup-check-finish second)
          (should-not (buffer-live-p owner)))
      (dolist (process (list first second))
        (when (process-live-p process) (delete-process process)))
      (when (buffer-live-p owner) (kill-buffer owner)))))

(ert-deftest neo-git-cleanup-running-commit-completes ()
  (save-window-excursion
    (let* ((root (file-name-as-directory (make-temp-file "neo-git-cleanup-" t)))
           (default-directory root)
           (owner (generate-new-buffer " *cleanup-real-commit*"))
           (release (expand-file-name "hook-release" root))
           process)
      (unwind-protect
          (progn
            (should (zerop (process-file (neo-git--executable) nil nil nil "init" "-q")))
            (with-temp-file (expand-file-name ".git/hooks/pre-commit" root)
              (insert "#!/bin/sh\nprintf ready > hook-ready\n"
                      "while test ! -f hook-release; do sleep 0.05; done\n"
                      "printf finished > hook-finished\n"))
            (set-file-modes (expand-file-name ".git/hooks/pre-commit" root) #o755)
            (switch-to-buffer owner)
            (neo-git-mode)
            (setq neo-git-root root)
            (neo-git--mutate '("-c" "user.name=Cleanup Check"
                               "-c" "user.email=check@example.invalid"
                               "-c" "commit.gpgsign=false"
                               "commit" "--allow-empty" "-m" "completed"))
            (setq process neo-git--mutation-process)
            (neo-git-cleanup-check-wait
             (lambda () (file-exists-p (expand-file-name "hook-ready" root))))
            (neo-git-quit)
            (should (buffer-live-p owner))
            (should (process-live-p process))
            (with-temp-file release (insert "continue\n"))
            (neo-git-cleanup-check-wait (lambda () (not (buffer-live-p owner))))
            (should (eq (plist-get (process-get process 'neo-git-log-entry) :status) 0))
            (should (file-exists-p (expand-file-name "hook-finished" root)))
            (should (equal (with-temp-buffer
                             (should (zerop (process-file (neo-git--executable) nil t nil
                                                          "-C" root "log" "-1" "--format=%s")))
                             (string-trim (buffer-string)))
                           "completed")))
        (with-temp-file release (insert "continue\n"))
        (when (process-live-p process)
          (neo-git-cleanup-check-wait (lambda () (not (process-live-p process)))))
        (when (buffer-live-p owner) (kill-buffer owner))
        (delete-directory root t)))))

(ert-deftest neo-git-cleanup-auxiliary-buffers ()
  (save-window-excursion
    (let ((owner (generate-new-buffer " *cleanup-auxiliary-owner*"))
          (browser (generate-new-buffer " *cleanup-auxiliary-browser*"))
          draft log show process message-file)
      (unwind-protect
          (progn
            (switch-to-buffer owner)
            (neo-git-mode)
            (setq neo-git-root default-directory
                  neo-git-entries '((:path "file.txt" :kind staged)))
            (setq draft (neo-git-commit))
            (goto-char (point-min))
            (insert "test commit\n")
            (neo-git-cleanup-check-process #'neo-git-commit-finish)
            (setq process (buffer-local-value 'neo-git--mutation-process owner)
                  message-file (car (last (plist-get (process-get process 'neo-git-log-entry)
                                                    :arguments))))
            (should (file-exists-p message-file))
            (neo-git-commit-cancel)
            (should (buffer-live-p draft))
            (should (process-live-p process))
            (should (file-exists-p message-file))
            (neo-git-cleanup-check-finish process)
            (should-not (buffer-live-p draft))
            (should-not (process-live-p process))
            (should-not (file-exists-p message-file))
            (switch-to-buffer owner)
            (setq draft (neo-git-commit))
            (with-current-buffer browser
              (neo-git-browser-mode)
              (setq neo-git--diff-owner owner neo-git-root default-directory
                    neo-git--browser-kind 'history
                    tabulated-list-format [("Commit" 12 nil)]
                    tabulated-list-entries '(("12345678" ["test commit"])))
              (tabulated-list-init-header)
              (tabulated-list-print t)
              (goto-char (point-min)))
            (switch-to-buffer browser)
            (neo-git-cleanup-check-process #'neo-git-browser-show)
            (setq show (current-buffer)
                  process (cl-find-if (lambda (p) (eq (process-get p 'neo-git-source) show))
                                      (process-list)))
            (should process)
            (funcall (lookup-key (current-local-map) (kbd "q")))
            (should-not (buffer-live-p show))
            (should-not (process-live-p process))
            (switch-to-buffer owner)
            (neo-git-open-log)
            (setq log (current-buffer))
            (funcall (lookup-key (current-local-map) (kbd "q")))
            (should-not (buffer-live-p log))
            (switch-to-buffer owner)
            (neo-git-open-log)
            (setq log (current-buffer))
            (kill-buffer owner)
            (dolist (buffer (list draft browser log))
              (should-not (buffer-live-p buffer))))
        (dolist (buffer (list owner browser draft log show))
          (when (buffer-live-p buffer) (kill-buffer buffer)))
        (when (process-live-p process) (delete-process process))
        (when (and message-file (file-exists-p message-file)) (delete-file message-file))))))

(ert-run-tests-batch-and-exit)
