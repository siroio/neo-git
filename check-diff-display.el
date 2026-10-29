;;; check-diff-display.el --- Diff presentation checks -*- lexical-binding: t; -*-
(require 'ert)
(load (expand-file-name "neo-git.el" (file-name-directory load-file-name)) nil t)

(defun neo-git-test-diff (text)
  (insert text)
  (diff-mode)
  (neo-git--decorate-diff))

(defun neo-git-test-prefix (line)
  (goto-char (point-min))
  (search-forward line)
  (get-text-property (line-beginning-position) 'line-prefix))

(ert-deftest neo-git-diff-display-preserves-text-and-numbers ()
  (with-temp-buffer
    (let ((text "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -9,3 +19,4 @@ function\n same\n-old value\n+new value\n+extra\n tail\n"))
      (neo-git-test-diff text)
      (should (equal text (buffer-substring-no-properties (point-min) (point-max))))
      (should (equal (neo-git-test-prefix "@@") "old new │ "))
      (should (equal (neo-git-test-prefix " same") "  9  19 │ "))
      (should (equal (neo-git-test-prefix "-old") " 10     │ "))
      (should (equal (neo-git-test-prefix "+new") "     20 │ "))
      (should (equal (neo-git-test-prefix "+extra") "     21 │ "))
      (should (equal (neo-git-test-prefix " tail") " 11  22 │ "))
      (should (equal (get-text-property (point) 'wrap-prefix) "        │ "))
      (should (assq 'diff-added face-remapping-alist))
      (let ((remapping (copy-tree face-remapping-alist))
            (position (point)))
        (neo-git--decorate-diff)
        (should (= position (point)))
        (should (equal remapping face-remapping-alist))
        (should (equal text (buffer-substring-no-properties (point-min) (point-max))))))))

(ert-deftest neo-git-diff-display-zero-counts-markers-and-file-boundaries ()
  (with-temp-buffer
    (neo-git-test-diff
     (concat "diff --git a/x b/x\n--- /dev/null\n+++ b/x\n@@ -0,0 +1,2 @@\n"
             "+one\n+++literal plus\n\\ No newline at end of file\n"
             "diff --git a/y b/y\n--- a/y\n+++ /dev/null\n@@ -8,2 +0,0 @@\n"
             "-two\n---literal minus\n\\ No newline at end of file\n"
             "diff --git a/z b/z\nBinary files a/z and b/z differ\n"))
    (should (equal (neo-git-test-prefix "+one") "      1 │ "))
    (should (equal (neo-git-test-prefix "+++literal") "      2 │ "))
    (should (equal (neo-git-test-prefix "-two") "  8     │ "))
    (should (equal (neo-git-test-prefix "---literal") "  9     │ "))
    (should-not (neo-git-test-prefix "--- /dev/null"))
    (should-not (neo-git-test-prefix "No newline"))
    (should-not (neo-git-test-prefix "Binary files"))))

(ert-deftest neo-git-diff-display-large-line-numbers-and-truncated-input ()
  (with-temp-buffer
    (neo-git-test-diff "@@ -9999,2 +10000,2 @@\n-before\n+after\n context\n+not a hunk\n@@ -2 +2 @@\n-partial")
    (should (equal (neo-git-test-prefix "-before") " 9999       │ "))
    (should (equal (neo-git-test-prefix " context") "10000 10001 │ "))
    (should-not (neo-git-test-prefix "+not a hunk"))
    (should (equal (neo-git-test-prefix "-partial") "    2       │ "))))

(ert-deftest neo-git-diff-display-unsupported-formats-stay-readable ()
  (dolist (text '("diff --cc x\n@@@ -1,1 -1,1 +1,1 @@@\n++merged\n"
                  "*** a/x\n--- b/x\n***************\n*** 1 ****\n-old\n"
                  "[Diff truncated at 1 MiB]\n"))
    (with-temp-buffer
      (neo-git-test-diff text)
      (should (equal text (buffer-substring-no-properties (point-min) (point-max))))
      (should-not (text-property-not-all (point-min) (point-max) 'line-prefix nil)))))

(ert-deftest neo-git-diff-display-refinement-and-refresh ()
  (let ((temporary-file-directory (file-name-directory (locate-library "neo-git")))
        (text "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-common old tail\n+common new tail\n"))
    (with-temp-buffer
      (neo-git--show-diff-result nil (current-buffer) 0 text "" '("x" unstaged) 0)
      (setq-local diff-font-lock-syntax nil)
      (font-lock-ensure)
      (let ((deadline (+ (float-time) 10)))
        (while (and neo-git--refine-process (< (float-time) deadline))
          (accept-process-output nil 0.01)))
      (goto-char (point-min))
      (search-forward "new")
      (should (eq (get-char-property (1- (point)) 'face) 'diff-refine-added))
      (should (eq (key-binding (kbd "SPC")) #'neo-git--owner-stage))
      (should (eq (key-binding (kbd "e")) #'neo-git-diff-visit-line))
      (font-lock-flush)
      (font-lock-ensure)
      (should (equal text (buffer-substring-no-properties (point-min) (point-max))))
      (should (equal (neo-git-test-prefix "+common") "      1 │ "))
      (let ((mapping (copy-tree face-remapping-alist)))
        (neo-git--show-diff-result nil (current-buffer) 0 text "" '("x" staged) 1)
        (should (equal mapping face-remapping-alist)))
      (neo-git--show-diff-result nil (current-buffer) 'output-limit "" "" nil 2)
      (should-not (text-property-not-all (point-min) (point-max) 'line-prefix nil)))))

(ert-deftest neo-git-diff-display-visit-and-selection ()
  (let* ((root (make-temp-file
                (expand-file-name "diff-display-" (file-name-directory (locate-library "neo-git"))) t))
         (file (expand-file-name "x" root))
         (owner (generate-new-buffer " *diff-owner*"))
         (preview (generate-new-buffer " *diff-preview*")))
    (unwind-protect
        (save-window-excursion
          (with-temp-file file (insert "first\nnew\nlast\n"))
          (with-current-buffer owner (setq-local neo-git-root (file-name-as-directory root)))
          (with-current-buffer preview
            (neo-git--show-diff-result
             owner preview 0 "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,3 +1,3 @@\n first\n-old\n+new\n last\n"
             "" '("x" unstaged) 0)
            (switch-to-buffer preview)
            (setq-local transient-mark-mode t)
            (goto-char (point-min))
            (search-forward "-old")
            (neo-git-diff-visual-line)
            (neo-git-diff-next-line)
            (should (equal (neo-git--partial-selected-lines) '(6 . 7)))
            (neo-git-diff-escape)
            (should-not mark-active)
            (neo-git-diff-visit-line)
            (should (equal buffer-file-name file))
            (should (= (line-number-at-pos) 2))))
      (dolist (buffer (list owner preview (get-file-buffer file)))
        (when (buffer-live-p buffer) (kill-buffer buffer)))
      (delete-directory root t))))

(ert-deftest neo-git-diff-display-commit-and-stash ()
  (dolist (kind '(history stash))
    (save-window-excursion
      (let ((text "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n")
            shown)
        (unwind-protect
            (with-temp-buffer
              (neo-git-browser-mode)
              (setq neo-git-root default-directory neo-git--browser-kind kind)
              (cl-letf (((symbol-function 'tabulated-list-get-id) (lambda () "display-test"))
                        ((symbol-function 'neo-git--run)
                         (lambda (_root _args callback &rest _)
                           (setq shown (current-buffer))
                           (funcall callback 0 text ""))))
                (neo-git-browser-show))
              (with-current-buffer shown
                (should (equal (neo-git-test-prefix "+new") "      1 │ "))
                (should (equal text (buffer-substring-no-properties (point-min) (point-max))))
                (should-not neo-git--diff-source)))
          (when (buffer-live-p shown) (kill-buffer shown)))))))
