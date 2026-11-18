;;; check-vcs.el --- Multi-VCS behavior checks -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'neo-git)
(require 'neo-vcs nil t)

(ert-deftest neo-vcs-detect-nearest-and-colocated ()
  ;; Choosing Git first would run the wrong workflow in a colocated workspace.
  (should (fboundp 'neo-vcs-detect))
  (let* ((root (make-temp-file "neo-vcs-detect-" t))
         (child (expand-file-name "child" root)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" root))
          (make-directory child)
          (should (eq (neo-vcs-detect child) 'git))
          (make-directory (expand-file-name ".jj" root))
          (should (eq (neo-vcs-detect child) 'jj))
          (make-directory (expand-file-name ".svn" child))
          (should (eq (neo-vcs-detect child) 'svn)))
      (delete-directory root t))))

(ert-deftest neo-vcs-paths-cannot-escape-workspace ()
  (should (fboundp 'neo-vcs--paths))
  (let* ((root (make-temp-file "neo-vcs-path-" t))
         (context (list :backend 'hg :root (file-name-as-directory root))))
    (unwind-protect
        (progn
          (should (equal (neo-vcs--paths context '((:path "日本語 [x] @1.txt")
                                                  (:path "-file.txt")))
                         '("日本語 [x] @1.txt" "-file.txt")))
          (dolist (path '("../outside" "/outside" "" "." "a/../../outside"))
            (should-error (neo-vcs--path context path) :type 'user-error))
          (should-error (neo-vcs--paths context nil) :type 'user-error))
      (delete-directory root t))))

(ert-deftest neo-vcs-json-preserves-literal-filenames ()
  (should (fboundp 'neo-vcs--json))
  (should (equal (neo-vcs--json "[{\"path\":\"line\\nquote\\\".txt\",\"flag\":false}]")
                 '(((path . "line\nquote\".txt") (flag))))))

(defun neo-vcs-check-wait (predicate)
  (let ((deadline (+ (float-time) 15)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))

(ert-deftest neo-vcs-sequence-stops-on-failure ()
  ;; Running a second command after failure could submit incomplete changes.
  (should (fboundp 'neo-vcs--execute))
  (let ((neo-vcs--backends nil)
        result done
        (owner (generate-new-buffer " *neo-vcs-sequence*")))
    (unwind-protect
        (progn
          (neo-vcs-register-backend
           'test :program (expand-file-name invocation-name invocation-directory))
          (with-current-buffer owner
            (neo-vcs-mode)
            (setq neo-vcs-context (list :backend 'test :root default-directory))
            (neo-vcs--execute
             neo-vcs-context
             '(:commands ((:args ("-Q" "--batch" "--eval" "(kill-emacs 7)"))
                          (:args ("-Q" "--batch" "--eval" "(princ \"unexpected\")"))))
             (lambda (status data errors) (setq result (list status data errors) done t))))
          (neo-vcs-check-wait (lambda () done))
          (should (equal (car result) 7))
          (should-not (string-match-p "unexpected" (format "%s" (cadr result)))))
      (kill-buffer owner))))

(ert-deftest neo-vcs-unsaved-files-block-mutations ()
  (should (fboundp 'neo-vcs--check-unsaved))
  (let* ((root (make-temp-file "neo-vcs-unsaved-" t))
         (file (expand-file-name "work.txt" root))
         (buffer (find-file-noselect file)))
    (unwind-protect
        (progn
          (with-current-buffer buffer (insert "unsaved"))
          (should-error (neo-vcs--check-unsaved (list :root root)) :type 'user-error))
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer)
      (delete-directory root t))))

(ert-deftest neo-vcs-successful-mutation-keeps-stderr-out-of-parsed-output ()
  (let ((neo-vcs--backends nil) parsed completion)
    (neo-vcs-register-backend
     'test :program (expand-file-name invocation-name invocation-directory)
     :request
     (lambda (_context operation _target _options)
       (pcase operation
         ('push
          (list :commands
                '((:args ("-Q" "--batch" "--eval"
                          "(progn (princ \"{\\\"ok\\\":true}\") (message \"Warning: first step\"))"))
                  (:args ("-Q" "--batch" "--eval"
                          "(progn (princ \"{\\\"changed\\\":false}\") (message \"Warning: Nothing changed\"))")))
                :parse (lambda (outputs) (setq parsed (mapcar #'neo-vcs--json outputs)))))
         ('status (list :parse (lambda (_) '(:entries nil))))
         ('history (list :parse (lambda (_) nil))))))
    (with-temp-buffer
      (neo-vcs-mode)
      (setq neo-vcs-context (list :backend 'test :root default-directory))
      (neo-vcs--mutate '(:id push :label "Push") nil nil
                       (lambda (status diagnostics) (setq completion (cons status diagnostics))))
      (neo-vcs-check-wait (lambda () completion))
      (should (equal parsed '(((ok . t)) ((changed)))))
      (should (equal completion '(0 . "Warning: first step\nWarning: Nothing changed")))
      (should (string-search "Warning: Nothing changed" neo-vcs--result)))))

(ert-deftest neo-vcs-ui-error-clears-all-stale-panes ()
  (let ((owner (generate-new-buffer " *neo-vcs-ui-test*")))
    (unwind-protect
        (with-current-buffer owner
          (neo-vcs-mode)
          (setq neo-vcs-context (list :backend 'test :root default-directory)
                neo-vcs--state '(:entries ((:path "old.txt" :status modified)))
                neo-vcs--history '((:id "old" :subject "Old history"))
                neo-git--preview-buffer (generate-new-buffer " *neo-vcs-ui-diff*")
                neo-vcs--history-buffer (generate-new-buffer " *neo-vcs-ui-history*"))
          (with-current-buffer neo-vcs--history-buffer
            (neo-vcs-history-mode) (setq neo-git--diff-owner owner))
          (with-current-buffer neo-git--preview-buffer (setq neo-git--diff-owner owner))
          (neo-vcs--render)
          (neo-vcs--render-history)
          (neo-vcs--show-text "stale diff" t)
          (neo-vcs--error "Server unavailable")
          (should-not tabulated-list-entries)
          (should-not (buffer-local-value 'tabulated-list-entries neo-vcs--history-buffer))
          (should (string-match-p "Server unavailable"
                                  (with-current-buffer neo-git--preview-buffer (buffer-string)))))
      (when (buffer-live-p owner) (kill-buffer owner)))))

(ert-deftest neo-vcs-write-sequence-survives-close ()
  (let ((neo-vcs--backends nil) done result
        (owner (generate-new-buffer " *neo-vcs-write-test*")))
    (unwind-protect
        (progn
          (neo-vcs-register-backend 'test :program (expand-file-name invocation-name invocation-directory))
          (with-current-buffer owner
            (neo-vcs-mode)
            (setq neo-vcs-context (list :backend 'test :root default-directory))
            (neo-vcs--execute
             neo-vcs-context
             '(:commands ((:args ("-Q" "--batch" "--eval" "(progn (sleep-for 0.2) (princ \"first\"))"))
                          (:args ("-Q" "--batch" "--eval" "(princ \"second\")"))))
             (lambda (status output _errors) (setq done t result (list status output))) t)
            (should-not (kill-buffer owner)))
          (neo-vcs-check-wait (lambda () done))
          (should (equal result '(0 "firstsecond")))
          (neo-vcs-check-wait (lambda () (not (buffer-live-p owner)))))
      (when (buffer-live-p owner) (kill-buffer owner)))))

(ert-deftest neo-vcs-preview-never-publishes-an-older-selection ()
  (let ((neo-vcs--backends nil)
        (owner (generate-new-buffer " *neo-vcs-stale-test*")))
    (unwind-protect
        (progn
          (neo-vcs-register-backend
           'test :program (expand-file-name invocation-name invocation-directory)
           :request (lambda (_context _operation target _options)
                      (list :commands (list (list :args
                                                 (list "-Q" "--batch" "--eval"
                                                       (if (equal (plist-get target :path) "old.txt")
                                                           "(progn (sleep-for 0.3) (princ \"old diff\"))"
                                                         "(princ \"new diff\")")))))))
          (with-current-buffer owner
            (neo-vcs-mode)
            (setq neo-vcs-context (list :backend 'test :root default-directory)
                  neo-vcs--state '(:entries ((:path "old.txt" :status modified)
                                            (:path "new.txt" :status modified)))
                  neo-git--preview-buffer (generate-new-buffer " *neo-vcs-stale-diff*"))
            (with-current-buffer neo-git--preview-buffer (setq neo-git--diff-owner owner))
            (neo-vcs--render)
            (goto-char (point-min))
            (neo-vcs--preview)
            (forward-line 1)
            (neo-vcs--preview)
            (neo-vcs-check-wait (lambda () (not neo-vcs--jobs)))
            (should (equal (with-current-buffer neo-git--preview-buffer (buffer-string)) "new diff"))))
      (when (buffer-live-p owner) (kill-buffer owner)))))

(ert-deftest neo-vcs-filtered-marks-do-not-target-hidden-files ()
  (with-temp-buffer
    (neo-vcs-mode)
    (setq neo-vcs-context (list :backend 'test :root default-directory)
          neo-vcs--state '(:entries ((:path "hidden.txt" :status modified)
                                    (:path "visible.txt" :status modified)))
          neo-vcs--marked '("hidden.txt") neo-vcs--filter "visible")
    (neo-vcs--render)
    (should-not (neo-vcs--selected-entries))))

(ert-deftest neo-vcs-mark-updates-only-selected-row ()
  (with-temp-buffer
    (neo-vcs-mode)
    (setq neo-vcs-context (list :backend 'test :root default-directory)
          neo-vcs--state '(:entries ((:path "a") (:path "b"))))
    (neo-vcs--render)
    (forward-line 1)
    (cl-letf (((symbol-function 'tabulated-list-print)
               (lambda (&rest _) (ert-fail "Marking reprinted the list"))))
      (neo-vcs-mark)
      (should (equal (tabulated-list-get-id) "b"))
      (should (equal (aref (tabulated-list-get-entry) 0) "*"))
      (should (equal (neo-vcs--selected-entries) '((:path "b"))))
      (neo-vcs-mark)
      (should-not neo-vcs--marked)
      (should (equal (aref (tabulated-list-get-entry) 0) "")))))

(ert-deftest neo-vcs-message-is-immutable-while-submitting ()
  (let ((neo-vcs--backends nil)
        (owner (generate-new-buffer " *neo-vcs-message-owner*"))
        (editor (generate-new-buffer " *neo-vcs-message-editor*")))
    (unwind-protect
        (progn
          (neo-vcs-register-backend
           'test :program (expand-file-name invocation-name invocation-directory)
           :request (lambda (_context operation _target _options)
                      (pcase operation
                        ('commit '(:commands ((:args ("-Q" "--batch" "--eval" "(sleep-for 0.2)")))))
                        ('status (list :parse (lambda (_) '(:entries nil))))
                        ('history (list :parse (lambda (_) nil))))))
          (with-current-buffer owner
            (neo-vcs-mode)
            (setq neo-vcs-context (list :backend 'test :root default-directory)))
          (with-current-buffer editor
            (neo-vcs-message-mode)
            (insert "Original message")
            (setq neo-vcs--message-owner owner
                  neo-vcs--message-action '(:id commit :label "Commit"))
            (neo-vcs-message-finish)
            (should buffer-read-only)
            (should-error (neo-vcs-message-finish) :type 'user-error)
            (should buffer-read-only)
            (should-error (insert "must not be lost") :type 'buffer-read-only))
          (neo-vcs-check-wait (lambda () (not (buffer-live-p editor)))))
      (when (buffer-live-p editor) (kill-buffer editor))
      (when (buffer-live-p owner) (kill-buffer owner)))))

(ert-deftest neo-vcs-write-output-limit-does-not-terminate-write ()
  (let ((neo-vcs--backends nil) result done
        (marker (make-temp-name (expand-file-name "neo-vcs-finished-" temporary-file-directory)))
        (owner (generate-new-buffer " *neo-vcs-limit-owner*")))
    (unwind-protect
        (progn
          (neo-vcs-register-backend 'test :program (expand-file-name invocation-name invocation-directory))
          (with-current-buffer owner
            (neo-vcs-mode)
            (setq neo-vcs-context (list :backend 'test :root default-directory))
            (neo-vcs--execute
             neo-vcs-context
             (list :limit 8 :commands
                   (list (list :args
                               (list "-Q" "--batch" "--eval"
                                     (format "(progn (princ (make-string 1000000 120)) (sleep-for 0.2) (with-temp-file %S (insert \"done\")))" marker)))))
             (lambda (status _output _errors) (setq result status done t)) t))
          (neo-vcs-check-wait (lambda () done))
          (should (eq result 'output-limit))
          (should (file-exists-p marker)))
      (when (buffer-live-p owner) (kill-buffer owner))
      (when (file-exists-p marker) (delete-file marker)))))

(ert-deftest neo-vcs-opens-a-fresh-empty-workspace ()
  (let ((neo-vcs--backends nil) owner)
    (neo-vcs-register-backend
     'test :program "unused" :actions nil
     :request (lambda (_context operation _target _options)
                (list :parse (if (eq operation 'status)
                                 (lambda (_) '(:label "Empty" :entries nil))
                               (lambda (_) nil)))))
    (save-window-excursion
      (unwind-protect
          (progn
            (setq owner (neo-vcs--open (list :backend 'test :root default-directory)))
            (with-current-buffer owner
              (should (derived-mode-p 'neo-vcs-mode))
              (should (equal (plist-get neo-vcs--state :label) "Empty"))
              (should-not neo-vcs--error)
              (should (buffer-live-p neo-vcs--history-buffer))
              (should (equal (with-current-buffer neo-git--preview-buffer (buffer-string))
                             "No file selected\n"))))
        (when (buffer-live-p owner) (kill-buffer owner))))))

(ert-deftest neo-vcs-failed-submit-keeps-message-editable ()
  (let ((neo-vcs--backends nil)
        (owner (generate-new-buffer " *neo-vcs-failed-owner*"))
        (editor (generate-new-buffer " *neo-vcs-failed-message*")))
    (unwind-protect
        (progn
          (neo-vcs-register-backend
           'test :program (expand-file-name invocation-name invocation-directory)
           :request (lambda (&rest _) '(:commands ((:args ("-Q" "--batch" "--eval" "(progn (sleep-for 0.2) (kill-emacs 7))"))))))
          (with-current-buffer owner
            (neo-vcs-mode)
            (setq neo-vcs-context (list :backend 'test :root default-directory)))
          (with-current-buffer editor
            (neo-vcs-message-mode)
            (insert "Keep this message")
            (setq neo-vcs--message-owner owner neo-vcs--message-action '(:id commit :label "Commit"))
            (neo-vcs-message-finish)
            (should-error (neo-vcs-message-finish) :type 'user-error)
            (should buffer-read-only))
          (neo-vcs-check-wait (lambda () (not (buffer-local-value 'neo-vcs--writing owner))))
          (should (buffer-live-p editor))
          (with-current-buffer editor
            (should-not buffer-read-only)
            (should (equal (buffer-string) "Keep this message"))
            (insert " and edit it")))
      (when (buffer-live-p editor) (kill-buffer editor))
      (when (buffer-live-p owner) (kill-buffer owner)))))

(ert-deftest neo-vcs-close-cancels-only-owned-reads ()
  (let ((neo-vcs--backends nil) job
        (owner (generate-new-buffer " *neo-vcs-close-read*"))
        (unrelated (generate-new-buffer " *neo-vcs-unrelated*")))
    (unwind-protect
        (progn
          (neo-vcs-register-backend 'test :program (expand-file-name invocation-name invocation-directory))
          (with-current-buffer owner
            (neo-vcs-mode)
            (setq neo-vcs-context (list :backend 'test :root default-directory)
                  job (neo-vcs--execute neo-vcs-context
                                        '(:commands ((:args ("-Q" "--batch" "--eval" "(sleep-for 10)"))))
                                        #'ignore)))
          (kill-buffer owner)
          (should-not (buffer-live-p owner))
          (should-not (process-live-p (neo-vcs--job-process job)))
          (should (buffer-live-p unrelated)))
      (when (buffer-live-p owner) (kill-buffer owner))
      (kill-buffer unrelated))))

(ert-deftest neo-vcs-failed-precondition-stops-before-mutation ()
  (let ((neo-vcs--backends nil) done result
        (marker (make-temp-name (expand-file-name "neo-vcs-precondition-" temporary-file-directory)))
        (owner (generate-new-buffer " *neo-vcs-precondition*")))
    (unwind-protect
        (progn
          (neo-vcs-register-backend 'test :program (expand-file-name invocation-name invocation-directory))
          (with-current-buffer owner
            (neo-vcs-mode)
            (setq neo-vcs-context (list :backend 'test :root default-directory))
            (neo-vcs--execute
             neo-vcs-context
             (list :commands
                   (list (list :args '("-Q" "--batch" "--eval" "(princ \"not merging\")")
                               :check (lambda (_) (user-error "No merge in progress")))
                         (list :args (list "-Q" "--batch" "--eval"
                                           (format "(with-temp-file %S (insert \"unexpected\"))" marker)))))
             (lambda (status _output errors) (setq result (list status errors) done t)) t))
          (neo-vcs-check-wait (lambda () done))
          (should (eq (car result) 'precondition-error))
          (should (string-match-p "No merge" (cadr result)))
          (should-not (file-exists-p marker)))
      (when (buffer-live-p owner) (kill-buffer owner))
      (when (file-exists-p marker) (delete-file marker)))))

(ert-deftest neo-vcs-evil-keeps-pane-navigation ()
  (skip-unless (require 'evil nil t))
  (let ((neo-vcs--backends nil) owner (was-enabled evil-mode))
    (neo-vcs-register-backend
     'test :program "unused" :actions nil
     :request (lambda (_context operation _target _options)
                (list :parse (if (eq operation 'status)
                                 (lambda (_) '(:label "Empty" :entries nil))
                               (lambda (_) nil)))))
    (save-window-excursion
      (unwind-protect
          (progn
            (evil-mode 1)
            (setq owner (neo-vcs--open (list :backend 'test :root default-directory)))
            (with-current-buffer owner
              (dolist (state '(normal motion))
                (evil-change-state state)
                (should (eq (key-binding (kbd "x")) #'neo-vcs-action-menu))
                (should (eq (key-binding (kbd "q")) #'neo-git-quit))
                (should (eq (key-binding (kbd "TAB")) #'neo-vcs-focus-diff)))
              (neo-vcs--show-text "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-a\n+b\n" t)
              (with-current-buffer neo-git--preview-buffer
                (evil-normal-state)
                (should (eq (key-binding (kbd "q")) #'neo-vcs-focus-list))))
            (with-current-buffer (buffer-local-value 'neo-vcs--history-buffer owner)
              (evil-normal-state)
              (should (eq (key-binding (kbd "RET")) #'neo-vcs-show-revision))))
        (when (buffer-live-p owner) (kill-buffer owner))
        (unless was-enabled (evil-mode -1))))))

(ert-deftest neo-vcs-q-restores-panes-and-original-split ()
  (save-window-excursion
    (delete-other-windows)
    (let ((left (generate-new-buffer " *neo-vcs-left*"))
          (right (generate-new-buffer " *neo-vcs-right*"))
          owner)
      (unwind-protect
          (progn
            (switch-to-buffer left)
            (select-window (split-window-right))
            (switch-to-buffer right)
            (let ((original (current-window-configuration))
                  ;; An ordinary pop-to-buffer may replace the current pane.
                  (display-buffer-overriding-action '((display-buffer-same-window))))
              (cl-letf (((symbol-function 'neo-vcs-refresh) #'ignore))
                (setq owner (neo-vcs--open (list :backend 'svn :root default-directory))))
              (select-window (get-buffer-window owner))
              (let ((history neo-vcs--history-buffer) (diff neo-git--preview-buffer)
                    (panes (current-window-configuration)))
                (dolist (step (list (cons "l" history) (cons "q" owner)
                                    (cons "TAB" diff) (cons "q" owner)))
                  (call-interactively (key-binding (kbd (car step))))
                  (should (eq (window-buffer) (cdr step)))
                  (should (eq (current-buffer) (cdr step))))
                (should (compare-window-configurations panes (current-window-configuration)))
                (call-interactively (key-binding (kbd "q")))
                (should-not (cl-some #'buffer-live-p (list owner history diff))))
              (should (compare-window-configurations original (current-window-configuration)))
              (should (eq (current-buffer) right))))
        (dolist (buffer (list owner left right))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest neo-vcs-status-reuses-parent-checks-but-validates-links ()
  (let* ((context (list :root temporary-file-directory))
         (neo-vcs--status-directories (make-hash-table :test #'equal))
         (link (expand-file-name "dir/link" temporary-file-directory))
         (symlink (symbol-function 'file-symlink-p))
         (parent (expand-file-name "dir" temporary-file-directory))
         (checks 0))
    (cl-letf (((symbol-function 'file-in-directory-p)
               (lambda (path _root)
                 (not (equal (directory-file-name path) link))))
              ((symbol-function 'file-symlink-p)
               (lambda (path)
                 (when (equal path parent) (cl-incf checks))
                 (if (equal path link) "../outside" (funcall symlink path)))))
      (dolist (path '("dir/a" "dir/b"))
        (should (equal (neo-vcs--path context path) path)))
      (should (= 1 checks))
      (should-error (neo-vcs--path context "dir/link") :type 'user-error)
      (should-error (neo-vcs--path context "dir/link/escaped") :type 'user-error))))

(ert-deftest neo-vcs-navigation-coalesces-and-reuses-preview ()
  (let ((neo-vcs--backends nil) calls)
    (neo-vcs-register-backend
     'test :request (lambda (_context _operation target _options)
                      (push (plist-get target :path) calls)
                      (list :parse (lambda (_) (car calls)))))
    (save-window-excursion
      (let ((owner (generate-new-buffer " *neo-vcs-move*")))
        (unwind-protect
            (progn
              (switch-to-buffer owner)
              (neo-vcs-mode)
              (setq neo-vcs-context (list :backend 'test :root default-directory)
                    neo-vcs--state '(:entries ((:path "a") (:path "b") (:path "c")))
                    neo-git--preview-buffer (generate-new-buffer " *neo-vcs-move-diff*"))
              (with-current-buffer neo-git--preview-buffer (setq neo-git--diff-owner owner))
              (neo-vcs--render)
              (neo-vcs-next)
              (neo-vcs-next)
              (should-not calls)
              (neo-vcs-check-wait (lambda () calls))
              (neo-vcs-focus-diff)
              (should (equal calls '("c")))
              (should (equal (buffer-string) "c"))
              (neo-vcs-focus-list)
              (neo-vcs-previous)
              (neo-vcs-focus-diff)
              (should (equal calls '("b" "c")))
              (should-not (buffer-local-value 'neo-vcs--preview-timer owner)))
          (kill-buffer owner))))))

(provide 'check-vcs)
;;; check-vcs.el ends here
