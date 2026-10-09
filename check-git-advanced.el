;;; check-git-advanced.el --- Advanced workflow integration checks -*- lexical-binding: t; -*-
(load (or (getenv "NEO_GIT_ADVANCED_SOURCE")
          (expand-file-name "neo-git.el" (file-name-directory load-file-name))) nil t)
(require 'ert)

(defun neo-git-advanced-git (&rest args)
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix)
          (coding-system-for-write (if (eq system-type 'windows-nt)
                                       w32-system-coding-system 'utf-8-unix)))
      (should (zerop (apply #'process-file (neo-git--executable) nil t nil args)))
      (string-trim (buffer-string)))))

(defun neo-git-advanced-wait (owner)
  (let ((deadline (+ (float-time) 15)))
    (while (and (or (buffer-local-value 'neo-git--mutation owner)
                    (buffer-local-value 'neo-git--refresh-process owner))
                (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should-not (buffer-local-value 'neo-git--mutation owner))))

(defmacro neo-git-advanced-repo (&rest body)
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "neo-git-advanced-" t)))
          (default-directory root)
          (process-environment (copy-sequence process-environment))
          (owner (generate-new-buffer " *advanced-owner*")))
     (setenv "GIT_CONFIG_GLOBAL" (expand-file-name "global-config" root))
     (setenv "GIT_CONFIG_NOSYSTEM" "1")
     (unwind-protect
         (progn
           (neo-git-advanced-git "init" "-q" "-b" "main")
           (neo-git-advanced-git "config" "user.name" "Advanced Check")
           (neo-git-advanced-git "config" "user.email" "check@example.invalid")
           (with-temp-file "file.txt" (insert "initial\n"))
           (neo-git-advanced-git "add" "file.txt")
           (neo-git-advanced-git "commit" "-qm" "initial 日本語")
           (with-current-buffer owner
             (neo-git-mode)
             (setq neo-git-root root neo-git--closed t))
           ,@body)
       (dolist (buffer (buffer-list))
         (when (or (eq buffer owner)
                   (and (buffer-local-value 'buffer-file-name buffer)
                        (string-prefix-p root (buffer-local-value 'buffer-file-name buffer)))
                   (eq (buffer-local-value 'neo-git--commit-status-buffer buffer) owner))
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (delete-directory root t))))

(defun neo-git-advanced-stage (owner text)
  (with-temp-file "file.txt" (insert text))
  (neo-git-advanced-git "add" "file.txt")
  (with-current-buffer owner
    (setq neo-git-entries
          (plist-get (neo-git--parse-status
                      (neo-git-advanced-git "status" "--porcelain=v2" "-z")) :entries))))

(defun neo-git-advanced-edit (owner kind message)
  (set-buffer
   (with-current-buffer owner
     (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
       (neo-git-commit kind))))
  (should (eq neo-git--commit-status-buffer owner))
  (erase-buffer)
  (insert message)
  (neo-git-commit-finish)
  (neo-git-advanced-wait owner))

(defun neo-git-advanced-editor-buffer (predicate)
  (let ((deadline (+ (float-time) 15)) buffer)
    (while (and (not buffer) (< (float-time) deadline))
      (accept-process-output nil 0.02)
      (setq buffer (cl-find-if predicate (buffer-list))))
    (unless buffer
      (message "Editor buffers: %S"
               (mapcar (lambda (b) (list (buffer-name b)
                                         (buffer-local-value 'buffer-file-name b)
                                         (buffer-local-value 'server-buffer-clients b)))
                       (buffer-list)))
      (maphash (lambda (_root entries) (message "Git log: %S" entries)) neo-git--command-logs))
    (should buffer)
    buffer))

(defun neo-git-advanced-select-row (oid)
  "Select an actual browser row instead of mocking an inlined accessor."
  (neo-git-advanced-editor-buffer
   (let ((browser (current-buffer)))
     (lambda (b) (and (eq b browser)
                      (not (buffer-local-value 'neo-git--browser-process b))))))
  (goto-char (point-min))
  (while (and (< (point) (point-max)) (not (equal oid (tabulated-list-get-id))))
    (forward-line))
  (should (equal oid (tabulated-list-get-id))))

(ert-deftest neo-git-advanced-amend-and-reword ()
  (neo-git-advanced-repo
    (neo-git-advanced-stage owner "amended\n")
    (neo-git-advanced-edit owner 'amend "amended 日本語")
    (should (equal "1" (neo-git-advanced-git "rev-list" "--count" "HEAD")))
    (should (equal "amended" (neo-git-advanced-git "show" "HEAD:file.txt")))
    (neo-git-advanced-stage owner "still staged\n")
    (let ((tree (neo-git-advanced-git "rev-parse" "HEAD^{tree}"))
          (index (neo-git-advanced-git "write-tree")))
      (neo-git-advanced-edit owner 'reword "message only")
      (should (equal "message only" (neo-git-advanced-git "log" "-1" "--format=%s")))
      (should (equal tree (neo-git-advanced-git "rev-parse" "HEAD^{tree}")))
      (should (equal index (neo-git-advanced-git "write-tree"))))))

(ert-deftest neo-git-advanced-fixup-and-guards ()
  (neo-git-advanced-repo
    (let ((target (neo-git-advanced-git "rev-parse" "HEAD")))
      (neo-git-advanced-stage owner "fix\n")
      (with-current-buffer owner (neo-git-commit-fixup target))
      (neo-git-advanced-wait owner)
      (should (equal "fixup! initial 日本語" (neo-git-advanced-git "log" "-1" "--format=%s")))
      (with-current-buffer owner
        (setq neo-git-entries nil)
        (should-error (neo-git-commit-fixup target) :type 'user-error)
        (setq neo-git--mutation t)
        (should-error (neo-git-commit 'reword) :type 'user-error)
        (setq neo-git--mutation nil)))))

(ert-deftest neo-git-advanced-stale-commit-draft ()
  (neo-git-advanced-repo
    (set-buffer
     (with-current-buffer owner
       (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
         (neo-git-commit 'reword))))
    (neo-git-advanced-git "commit" "--allow-empty" "-qm" "external commit")
    (should-error (neo-git-commit-finish) :type 'user-error)
    (should (buffer-live-p (current-buffer)))
    (should (equal "external commit" (neo-git-advanced-git "log" "-1" "--format=%s")))))

(ert-deftest neo-git-advanced-conflict-resolution ()
  (neo-git-advanced-repo
    (neo-git-advanced-git "switch" "-qc" "side")
    (with-temp-file "file.txt" (insert "other\n"))
    (neo-git-advanced-git "commit" "-qam" "other")
    (neo-git-advanced-git "switch" "-q" "main")
    (with-temp-file "file.txt" (insert "mine\n"))
    (neo-git-advanced-git "commit" "-qam" "mine")
    (should (= 1 (process-file (neo-git--executable) nil nil nil "merge" "side")))
    (with-current-buffer owner
      (setq neo-git--closed nil
            neo-git-entries
            (plist-get (neo-git--parse-status
                        (neo-git-advanced-git "status" "--porcelain=v2" "-z")) :entries))
      (neo-git--render)
      (goto-char (point-min))
      (search-forward "file.txt")
      (beginning-of-line)
      (neo-git-visit-file))
    (set-buffer (find-file-noselect "file.txt"))
    (should smerge-mode)
    (should neo-git-conflict-mode)
    (should (looking-at "<<<<<<<"))
    (should-error (neo-git-conflict-finish) :type 'user-error)
    (smerge-keep-upper)
    (neo-git-conflict-finish)
    (neo-git-advanced-wait owner)
    (should (equal "mine" (neo-git-advanced-git "show" ":file.txt")))
    (should (string-empty-p (neo-git-advanced-git "diff" "--name-only" "--diff-filter=U")))
    (with-current-buffer owner
      (cl-letf (((symbol-function 'read-char-choice) (lambda (&rest _) ?c)))
        (neo-git-continue)))
    (neo-git-advanced-wait owner)
    (with-current-buffer owner (should-not (neo-git--in-progress-p)))))

(ert-deftest neo-git-advanced-interactive-rebase-editor ()
  (neo-git-advanced-repo
    (let ((base (neo-git-advanced-git "rev-parse" "HEAD")))
      (neo-git-advanced-stage owner "feature\n")
      (neo-git-advanced-git "commit" "-qm" "feature")
      (let ((target (neo-git-advanced-git "rev-parse" "HEAD")))
        (neo-git-advanced-stage owner "fixed\n")
        (with-current-buffer owner (neo-git-commit-fixup target))
        (neo-git-advanced-wait owner))
      (with-current-buffer owner
        (setq neo-git--closed nil)
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
          (neo-git-rebase-interactive base t)))
      (let ((deadline (+ (float-time) 15)) todo)
        (while (and (not todo) (< (float-time) deadline))
          (accept-process-output nil 0.02)
          (setq todo (cl-find-if
                      (lambda (b) (eq (buffer-local-value 'major-mode b) 'neo-git-sequence-mode))
                      (buffer-list))))
        (should todo)
        (with-current-buffer todo
          (should (string-match-p "^fixup " (buffer-string)))
          (neo-git-editor-finish)))
      (neo-git-advanced-wait owner)
      (should-not (buffer-local-value 'neo-git--last-error owner))
      (should (equal "2" (neo-git-advanced-git "rev-list" "--count" "HEAD")))
      (should (equal "fixed" (neo-git-advanced-git "show" "HEAD:file.txt"))))))

(ert-deftest neo-git-advanced-recovery-branch-and-revert ()
  (neo-git-advanced-repo
    (let ((initial (neo-git-advanced-git "rev-parse" "HEAD")))
      (neo-git-advanced-stage owner "second\n")
      (neo-git-advanced-git "commit" "-qm" "second")
      (with-current-buffer owner
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "recovered")))
          (neo-git-recover-commit initial)))
      (neo-git-advanced-wait owner)
      (should (equal initial (neo-git-advanced-git "rev-parse" "recovered")))
      (should (equal "main" (neo-git-advanced-git "branch" "--show-current")))
      (with-current-buffer owner
        (setq neo-git--closed nil)
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
          (neo-git-revert-commit (neo-git-advanced-git "rev-parse" "HEAD"))))
      (neo-git-advanced-wait owner)
      (should (equal "initial" (neo-git-advanced-git "show" "HEAD:file.txt"))))))

(ert-deftest neo-git-advanced-rebase-reword-and-cancel ()
  (neo-git-advanced-repo
    (let ((base (neo-git-advanced-git "rev-parse" "HEAD")))
      (neo-git-advanced-stage owner "feature\n")
      (neo-git-advanced-git "commit" "-qm" "feature")
      (with-current-buffer owner
        (setq neo-git--closed nil)
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
          (neo-git-rebase-interactive base)))
      (with-current-buffer
          (neo-git-advanced-editor-buffer
           (lambda (b) (eq (buffer-local-value 'major-mode b) 'neo-git-sequence-mode)))
        (goto-char (point-min))
        (re-search-forward "^pick ")
        (beginning-of-line)
        (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "reword")))
          (neo-git-sequence-action))
        (neo-git-editor-finish))
      (with-current-buffer
          (neo-git-advanced-editor-buffer
           (lambda (b)
             (and (buffer-local-value 'server-buffer-clients b)
                  (let ((file (buffer-local-value 'buffer-file-name b)))
                    (and file (equal (file-name-nondirectory file) "COMMIT_EDITMSG"))))))
        (erase-buffer)
        (insert "reworded through Git editor\n")
        (neo-git-editor-finish))
      (neo-git-advanced-wait owner)
      (should-not (buffer-local-value 'neo-git--last-error owner))
      (should (equal "reworded through Git editor" (neo-git-advanced-git "log" "-1" "--format=%s")))
      (let ((head (neo-git-advanced-git "rev-parse" "HEAD")))
        (with-current-buffer owner
          (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
            (neo-git-rebase-interactive base)))
        (with-current-buffer
            (neo-git-advanced-editor-buffer
             (lambda (b) (and (eq (buffer-local-value 'major-mode b) 'neo-git-sequence-mode)
                              (buffer-local-value 'server-buffer-clients b))))
          (neo-git-editor-cancel))
        (neo-git-advanced-wait owner)
        (should (buffer-local-value 'neo-git--last-error owner))
        (should (equal head (neo-git-advanced-git "rev-parse" "HEAD")))))))

(ert-deftest neo-git-advanced-reflog-browser-and-reset ()
  (neo-git-advanced-repo
    (let ((initial (neo-git-advanced-git "rev-parse" "HEAD")))
      (neo-git-advanced-stage owner "second\n")
      (neo-git-advanced-git "commit" "-qm" "second")
      (with-current-buffer owner (setq neo-git--closed nil))
      (let ((browser (neo-git--browser-buffer 'reflog owner)))
        (neo-git-advanced-editor-buffer
         (lambda (b) (and (eq b browser) (buffer-local-value 'tabulated-list-entries b))))
        (with-current-buffer browser
          (should (string-match-p "HEAD@{0}" (buffer-string)))
          (neo-git-advanced-select-row initial)
          (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "from-reflog")))
            (neo-git-browser-create-branch)))
        (neo-git-advanced-wait owner)
        (should (equal initial (neo-git-advanced-git "rev-parse" "from-reflog")))
        (should (equal "main" (neo-git-advanced-git "branch" "--show-current")))
        (with-current-buffer browser
          (neo-git-advanced-select-row initial)
          (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "soft"))
                    ((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
            (neo-git-reset-commit)))
        (should-not (equal initial (neo-git-advanced-git "rev-parse" "HEAD")))
        (with-current-buffer browser
          (neo-git-advanced-select-row initial)
          (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "soft"))
                    ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
            (neo-git-reset-commit)))
        (neo-git-advanced-wait owner)
        (should (equal initial (neo-git-advanced-git "rev-parse" "HEAD")))
        (should (equal "second" (neo-git-advanced-git "show" ":file.txt")))
        (kill-buffer browser)))))

(ert-deftest neo-git-advanced-conflict-markers-outside-narrowing ()
  (neo-git-advanced-repo
    (with-current-buffer (find-file-noselect "file.txt")
      (setq neo-git--conflict-owner owner)
      (dolist (marker '("<<<<<<< ours" "||||||| base" "=======" ">>>>>>> theirs" "<<<<<<<<< ours"))
        (erase-buffer)
        (insert "resolved here\n" marker "\n")
        (save-restriction
          (narrow-to-region (point-min) (+ (point-min) 14))
          (should-error (neo-git-conflict-finish) :type 'user-error)))
      (should (equal "initial" (neo-git-advanced-git "show" ":file.txt"))))))

(ert-deftest neo-git-advanced-rebase-structural-lines ()
  (with-temp-buffer
    (neo-git-sequence-mode)
    (dolist (line '("label onto\n" "reset onto\n" "merge -C deadbeef branch\n"))
      (erase-buffer) (insert line) (goto-char (point-min))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "pick")))
        (should-error (neo-git-sequence-action) :type 'user-error))
      (should (equal line (buffer-string))))))

(ert-deftest neo-git-advanced-preview-window-reused ()
  (save-window-excursion
    (with-temp-buffer
      (neo-git-mode)
      (setq neo-git-root default-directory)
      (switch-to-buffer (current-buffer))
      (let ((reused (selected-window)))
        (setq neo-git--preview-window reused)
        (neo-git--ensure-preview)
        (unwind-protect
            (should-not (eq reused neo-git--preview-window))
          (when (buffer-live-p neo-git--preview-buffer) (kill-buffer neo-git--preview-buffer)))))))

(ert-deftest neo-git-advanced-conflict-literal-path ()
  (neo-git-advanced-repo
    (with-temp-file "[x].txt" (insert "literal baseline\n"))
    (with-temp-file "x.txt" (insert "other baseline\n"))
    (neo-git-advanced-git "add" ".")
    (neo-git-advanced-git "commit" "-qm" "pathspec fixture")
    (with-temp-file "x.txt" (insert "unrelated edit\n"))
    (with-current-buffer (find-file-noselect "[x].txt")
      (erase-buffer) (insert "resolved literal\n")
      (setq neo-git--conflict-owner owner)
      (neo-git-conflict-finish))
    (neo-git-advanced-wait owner)
    (should (equal "resolved literal" (neo-git-advanced-git "show" ":[x].txt")))
    (should (equal "other baseline" (neo-git-advanced-git "show" ":x.txt")))))

(ert-deftest neo-git-advanced-failed-merge-reloads-saved-buffer ()
  (neo-git-advanced-repo
    (neo-git-advanced-git "switch" "-qc" "side")
    (with-temp-file "file.txt" (insert "other\n"))
    (neo-git-advanced-git "commit" "-qam" "other")
    (neo-git-advanced-git "switch" "-q" "main")
    (with-temp-file "file.txt" (insert "mine\n"))
    (neo-git-advanced-git "commit" "-qam" "mine")
    (let ((file-buffer (find-file-noselect "file.txt")))
      (with-current-buffer owner
        (setq neo-git--closed nil)
        (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "side")))
          (neo-git-merge)))
      (neo-git-advanced-wait owner)
      (should (buffer-local-value 'neo-git--last-error owner))
      (with-current-buffer file-buffer
        (should (string-match-p "<<<<<<<" (buffer-string)))
        (should-not (buffer-modified-p))))))

(ert-run-tests-batch-and-exit (or (getenv "NEO_GIT_TEST") t))
