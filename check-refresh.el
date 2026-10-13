;;; check-refresh.el --- Deleted repository refresh checks -*- lexical-binding: t; -*-
(load (expand-file-name "neo-git.el" (file-name-directory load-file-name)) nil t)
(require 'ert)

(defun neo-git-refresh-check-wait (predicate)
  (let ((deadline (+ (float-time) 15)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (should (funcall predicate))))

(ert-deftest neo-git-refresh-deleted-repository ()
  (dolist (metadata-only '(nil t))
    (let* ((parent (file-name-as-directory (make-temp-file "neo-git-refresh-" t)))
           (root (expand-file-name "nested/" parent))
           (default-directory temporary-file-directory)
           (owner (generate-new-buffer " *neo-git-refresh-check*"))
           (preview (generate-new-buffer " *neo-git-refresh-preview*"))
           history)
      (unwind-protect
          (progn
            (make-directory root)
            (should (zerop (process-file (neo-git--executable) nil nil nil
                                        "-C" parent "init" "-q")))
            (should (zerop (process-file (neo-git--executable) nil nil nil
                                        "-C" root "init" "-q")))
            (with-temp-file (expand-file-name "stale.txt" root) (insert "stale preview\n"))
            (should (zerop (process-file (neo-git--executable) nil nil nil
                                        "-C" root "add" "stale.txt")))
            (should (zerop (process-file (neo-git--executable) nil nil nil
                                        "-C" root "-c" "user.name=Check"
                                        "-c" "user.email=check@example.invalid"
                                        "-c" "commit.gpgsign=false" "commit" "-qm" "stale history")))
            (with-temp-file (expand-file-name "stale.txt" root) (insert "changed preview\n"))
            (with-current-buffer owner
              (neo-git-mode)
              (setq neo-git-root root neo-git--preview-buffer preview)
              (neo-git-refresh))
            (neo-git-refresh-check-wait
             (lambda () (with-current-buffer owner (not neo-git--status-updating))))
            (with-current-buffer owner (should neo-git-entries))
            (neo-git-refresh-check-wait
             (lambda () (with-current-buffer preview (string-match-p "changed preview" (buffer-string)))))
            (setq history (neo-git--browser-buffer 'history owner))
            (neo-git-refresh-check-wait
             (lambda () (with-current-buffer history (not neo-git--browser-process))))
            (with-current-buffer history (should tabulated-list-entries))
            (delete-directory (if metadata-only (expand-file-name ".git" root) root) t)
            (with-current-buffer owner (neo-git-refresh))
            (neo-git-refresh-check-wait
             (lambda () (with-current-buffer owner (not neo-git--status-updating))))
            (with-current-buffer owner
              (should-not neo-git-entries)
              (should-not neo-git-state)
              (should (string-match-p "Status unavailable" (buffer-string)))
              (should-not (string-match-p "Working tree clean" (buffer-string)))
              (should-not (string-match-p "stale.txt" (buffer-string))))
            (with-current-buffer preview
              (should-not neo-git--diff-id)
              (should-not (string-match-p "changed preview" (buffer-string))))
            (neo-git-refresh-check-wait
             (lambda () (with-current-buffer history (not neo-git--browser-process))))
            (with-current-buffer history
              (should-not tabulated-list-entries)
              (should-not (string-match-p "stale history" (buffer-string))))
            (make-directory root t)
            (should (zerop (process-file (neo-git--executable) nil nil nil
                                        "-C" root "init" "-q")))
            (with-temp-file (expand-file-name "recovered.txt" root) (insert "recovered\n"))
            (should (zerop (process-file (neo-git--executable) nil nil nil
                                        "-C" root "add" "recovered.txt")))
            (should (zerop (process-file (neo-git--executable) nil nil nil
                                        "-C" root "-c" "user.name=Check"
                                        "-c" "user.email=check@example.invalid"
                                        "-c" "commit.gpgsign=false" "commit" "-qm" "recovered history")))
            (with-temp-file (expand-file-name "recovered.txt" root) (insert "changed recovery\n"))
            (with-current-buffer owner (neo-git-refresh))
            (neo-git-refresh-check-wait
             (lambda () (with-current-buffer owner (not neo-git--status-updating))))
            (with-current-buffer owner
              (should (string-match-p "recovered.txt" (buffer-string)))
              (should-not (string-match-p "Status unavailable" (buffer-string))))
            (neo-git-refresh-check-wait
             (lambda () (with-current-buffer history (not neo-git--browser-process))))
            (with-current-buffer history
              (should (string-match-p "recovered history" (buffer-string)))))
        (dolist (buffer (list owner preview history))
          (when (buffer-live-p buffer) (kill-buffer buffer)))
        (when (file-directory-p parent) (delete-directory parent t))))))

(ert-run-tests-batch-and-exit)
