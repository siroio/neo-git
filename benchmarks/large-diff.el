;;; large-diff.el --- Large preview latency and refinement completion -*- lexical-binding: t; -*-
;; Run in a separate Emacs: -Q --batch -l benchmarks/large-diff.el.
;; Writes only under neo-git/var and the requested JSON output path.
(require 'cl-lib)
(require 'json)
(defconst neo-git-large-directory
  (file-name-directory (directory-file-name (file-name-directory load-file-name))))
(setq temporary-file-directory (expand-file-name "var/large-diff/" neo-git-large-directory)
      user-emacs-directory temporary-file-directory
      native-comp-jit-compilation nil)
(make-directory temporary-file-directory t)
(defconst neo-git-large-source
  (or (getenv "NEO_GIT_LARGE_DIFF_SOURCE")
      (expand-file-name "neo-git.el" neo-git-large-directory)))
(load neo-git-large-source nil t)

(defun neo-git-large-command (root &rest arguments)
  (with-temp-buffer
    (let ((status (apply #'process-file (neo-git--executable) nil t nil
                         "-C" root arguments)))
      (cl-assert (zerop status) nil "Git failed: %s" (buffer-string))
      (buffer-string))))

(let* ((root (make-temp-file "repository-" t))
       (default-directory (file-name-as-directory root))
       (process-environment (copy-sequence process-environment))
       (count 400)
       (samples nil))
  (setenv "GIT_CONFIG_GLOBAL" (expand-file-name "empty-config" root))
  (setenv "GIT_CONFIG_NOSYSTEM" "1")
  (unwind-protect
      (progn
        (neo-git-large-command root "init" "-q")
        (neo-git-large-command root "config" "user.name" "Benchmark")
        (neo-git-large-command root "config" "user.email" "benchmark@example.invalid")
        (dolist (value '(1 2))
          (with-temp-file "dense.el"
            (dotimes (n count)
              (insert (format "(setq v%d %d)\n(same %d)\n" n value n))))
          (when (= value 1)
            (neo-git-large-command root "add" "dense.el")
            (neo-git-large-command root "commit" "-qm" "baseline")))
        (dotimes (sample 3)
          (let ((preview (generate-new-buffer " *large-diff-preview*"))
                (started (float-time))
                git-ms display-ms output-size ready timer last-tick max-gap)
            (unwind-protect
                (with-current-buffer preview
                  (setq last-tick (float-time) max-gap 0
                        timer (run-at-time
                               0.01 0.01
                               (lambda ()
                                 (let ((now (float-time)))
                                   (setq max-gap (max max-gap (- now last-tick))
                                         last-tick now)))))
                  (neo-git--run
                   root (neo-git--diff-arguments "dense.el" 'unstaged)
                   (lambda (status text errors)
                     (setq git-ms (* 1000 (- (float-time) started))
                           output-size (string-bytes text))
                     (cl-assert (eql status 0) nil "%s" errors)
                     (neo-git--show-diff-result nil preview status text errors)
                     (setq ready t))
                   neo-git--limit)
                  (let ((deadline (+ started 15)))
                    (while (and (not ready) (< (float-time) deadline))
                      (accept-process-output nil 0.005)))
                  (cl-assert ready)
                  (goto-char (point-min))
                  (when (display-graphic-p) (switch-to-buffer preview))
                  (font-lock-ensure (point-min) (save-excursion (forward-line 60) (point)))
                  (when (display-graphic-p) (redisplay t))
                  (setq display-ms (* 1000 (- (float-time) started)))
                  (let ((deadline (+ (float-time) 120)))
                    (while (and (or (bound-and-true-p neo-git--refine-process)
                                    (bound-and-true-p neo-git--refine-queue))
                                (< (float-time) deadline))
                      (accept-process-output nil 0.005)))
                  (cl-assert (not (bound-and-true-p neo-git--refine-process)))
                  (cl-assert (not (bound-and-true-p neo-git--refine-queue)))
                  (accept-process-output nil 0.02)
                  (let ((refined (cl-count-if
                                  (lambda (overlay)
                                    (memq (overlay-get overlay 'face)
                                          '(diff-refine-added diff-refine-removed)))
                                  (overlays-in (point-min) (point-max)))))
                    (cl-assert (= refined (* count 2)))
                    (push `((sample . ,(1+ sample)) (bytes . ,output-size)
                            (git_ms . ,git-ms) (display_ms . ,display-ms)
                            (complete_ms . ,(* 1000 (- (float-time) started)))
                            (max_timer_gap_ms . ,(* 1000 max-gap))
                            (refined_overlays . ,refined)) samples)
                    (message "Large diff sample %d: %S" (1+ sample) (car samples))))
              (when timer (cancel-timer timer))
              (when (buffer-live-p preview) (kill-buffer preview)))))
        (let ((coding-system-for-write 'utf-8-unix))
          (with-temp-file (or (getenv "NEO_GIT_LARGE_DIFF_OUTPUT")
                              (expand-file-name "result.json" temporary-file-directory))
            (insert (json-encode
                     `((emacs . ,emacs-version)
                       (graphic . ,(if (display-graphic-p) t :json-false))
                       (source_sha256 . ,(with-temp-buffer
                                           (insert-file-contents-literally neo-git-large-source)
                                           (secure-hash 'sha256 (current-buffer))))
                       (changes . ,count)
                       (samples . ,(vconcat (nreverse samples)))))))))
    (delete-directory root t)))
(kill-emacs 0)
