;;; check-diff-performance.el --- Responsive diff refinement checks -*- lexical-binding: t; -*-
(require 'ert)
(require 'smerge-mode)
(load (expand-file-name "neo-git.el" (file-name-directory load-file-name)) nil t)

(defconst neo-git-test-dense-diff
  (concat "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,6 +1,6 @@\n"
          "-common old tail\n+common new tail\n context\n"
          "-日本語 before\n+日本語 after\n context\n"
          "-last old value\n+last new value\n end\n"))

(defun neo-git-test-wait-refinement ()
  (let ((deadline (+ (float-time) 15)))
    (while (and (or neo-git--refine-process neo-git--refine-queue)
                (< (float-time) deadline))
      (accept-process-output nil 0.01))
    (should-not neo-git--refine-process)
    (should-not neo-git--refine-queue)))

(defun neo-git-test-refined-faces ()
  (let (faces)
    (dotimes (offset (buffer-size))
      (let ((face (get-char-property (1+ offset) 'face)))
        (when (memq face '(diff-refine-added diff-refine-removed diff-refine-changed))
          (push (cons offset face) faces))))
    (nreverse faces)))

(ert-deftest neo-git-diff-refinement-does-not-block-font-lock ()
  (skip-unless (fboundp 'smerge--refine-prepare-regions))
  (with-temp-buffer
    (neo-git--show-diff-result nil (current-buffer) 0 neo-git-test-dense-diff "")
    (cl-letf (((symbol-function 'smerge-refine-regions)
               (lambda (&rest _) (ert-fail "Redisplay ran synchronous refinement"))))
      (font-lock-ensure))
    (neo-git-test-wait-refinement)
    (should (neo-git-test-refined-faces))
    (should (equal neo-git-test-dense-diff
                   (buffer-substring-no-properties (point-min) (point-max))))))

(ert-deftest neo-git-diff-refinement-matches-standard-diff-mode ()
  (let ((expected (with-temp-buffer
                    (insert neo-git-test-dense-diff)
                    (diff-mode)
                    (font-lock-ensure)
                    (neo-git-test-refined-faces))))
    (should expected)
    (with-temp-buffer
      (neo-git--show-diff-result nil (current-buffer) 0 neo-git-test-dense-diff "")
      (font-lock-ensure)
      (neo-git-test-wait-refinement)
      (should (equal expected (neo-git-test-refined-faces)))
      (font-lock-flush)
      (font-lock-ensure)
      (neo-git-test-wait-refinement)
      (should (equal expected (neo-git-test-refined-faces))))))

(ert-deftest neo-git-diff-refinement-cancels-on-refresh-and-close ()
  (skip-unless (fboundp 'smerge--refine-prepare-regions))
  (let* ((temporary-file-directory (make-temp-file "neo-git-refine-" t))
         (preview (generate-new-buffer " *neo-git-refine-test*")))
    (unwind-protect
        (with-current-buffer preview
          (neo-git--show-diff-result nil preview 0 neo-git-test-dense-diff "")
          (font-lock-ensure)
          (should neo-git--refine-process)
          (should neo-git--refine-queue)
          (neo-git--show-diff-result nil preview 0 "replacement\n" "")
          (neo-git-test-wait-refinement)
          (should-not (neo-git-test-refined-faces))
          (should (equal (directory-files temporary-file-directory) '("." "..")))
          (neo-git--show-diff-result nil preview 0 neo-git-test-dense-diff "")
          (font-lock-ensure)
          (let ((process neo-git--refine-process))
            (should (processp process))
            (kill-buffer preview)
            (should-not (process-live-p process)))
          (should (equal (directory-files temporary-file-directory) '("." ".."))))
      (when (buffer-live-p preview) (kill-buffer preview))
      (delete-directory temporary-file-directory t))))

(ert-deftest neo-git-diff-refinement-respects-options-and-older-emacs ()
  (dolist (option '(nil navigation))
    (let ((diff-refine option))
      (with-temp-buffer
        (neo-git--show-diff-result nil (current-buffer) 0 neo-git-test-dense-diff "")
        (font-lock-ensure)
        (should-not neo-git--refine-process)
        (should-not (neo-git-test-refined-faces)))))
  (with-temp-buffer
    (neo-git--show-diff-result nil (current-buffer) 0 neo-git-test-dense-diff "")
    (let ((prepare (symbol-function 'smerge--refine-prepare-regions))
          (refine (symbol-function 'smerge-refine-regions))
          called)
      (unwind-protect
          (progn
            (fmakunbound 'smerge--refine-prepare-regions)
            (cl-letf (((symbol-function 'smerge-refine-regions)
                       (lambda (&rest _) (setq called t))))
              (font-lock-ensure)))
        (fset 'smerge--refine-prepare-regions prepare)
        (fset 'smerge-refine-regions refine))
      (should called)
      (should-not neo-git--refine-process))))

(ert-deftest neo-git-diff-refinement-failure-cleans-up ()
  (skip-unless (fboundp 'smerge--refine-prepare-regions))
  (let* ((temporary-file-directory (make-temp-file "neo-git-refine-failure-" t))
         (diff-command "neo-git-nonexistent-diff-command"))
    (unwind-protect
        (with-temp-buffer
          (neo-git--show-diff-result nil (current-buffer) 0 neo-git-test-dense-diff "")
          (font-lock-ensure)
          (neo-git-test-wait-refinement)
          (should-not (neo-git-test-refined-faces))
          (should (equal neo-git-test-dense-diff
                         (buffer-substring-no-properties (point-min) (point-max))))
          (should (equal (directory-files temporary-file-directory) '("." ".."))))
      (delete-directory temporary-file-directory t))))

(ert-deftest neo-git-diff-refinement-handles-unicode-temporary-path ()
  (skip-unless (fboundp 'smerge--refine-prepare-regions))
  (let ((temporary-file-directory (make-temp-file "neo-git-refine-日本語 " t)))
    (unwind-protect
        (with-temp-buffer
          (neo-git--show-diff-result nil (current-buffer) 0 neo-git-test-dense-diff "")
          (font-lock-ensure)
          (neo-git-test-wait-refinement)
          (should (neo-git-test-refined-faces))
          (should (equal (directory-files temporary-file-directory) '("." ".."))))
      (delete-directory temporary-file-directory t))))
