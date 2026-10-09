;;; compare-gui.el --- Disposable GUI workflow comparison -*- lexical-binding: t; -*-
;; Load after the user's normal init, in a separate GUI Emacs. This runner
;; writes only its output file and a newly created temporary Git repository.
(require 'cl-lib)
(require 'json)
(defvar neo-git-compare-output (getenv "NEO_GIT_COMPARE_OUTPUT"))
(defvar neo-git-compare-package-directory (getenv "NEO_GIT_COMPARE_PACKAGES"))
(defvar neo-git-compare-count 10)
(defvar neo-git-compare-files 200)
(defvar neo-git-compare-samples nil)
(defconst neo-git-compare-source
  (expand-file-name "../neo-git.el" (file-name-directory load-file-name)))

(defun neo-git-compare-git (&rest args)
  (with-temp-buffer
    (unless (zerop (apply #'process-file "git" nil t nil args))
      (error "Git %S: %s" args (buffer-string)))
    (string-trim (buffer-string))))

(defun neo-git-compare-wait (ready)
  (let ((deadline (+ (float-time) 30)))
    (while (and (not (funcall ready)) (< (float-time) deadline))
      (accept-process-output nil 0.005))
    (unless (funcall ready) (error "Timed out waiting for the operation"))))

(defun neo-git-compare-neo-ready (root)
  (let ((owner (get-buffer (format "*Neo Git: %s*" (directory-file-name root)))))
    (and owner (get-buffer-window owner)
         (with-current-buffer owner
           (and (not neo-git--status-updating) (not neo-git--mutation)
                (not neo-git--refresh-process) (not neo-git--refresh-pending)
                (not neo-git--refresh-timer) (not neo-git--diff-process)
                (not neo-git--stage-prefetch) neo-git-state
                (let ((history (get-buffer (format "*Neo Git history: %s*" root))))
                  (or (not history)
                      (not (buffer-local-value 'neo-git--browser-process history)))))))))

(defun neo-git-compare-measure (tool operation action ready)
  (let ((start (float-time)))
    (funcall action)
    (neo-git-compare-wait ready)
    (redisplay t)
    (push `((tool . ,tool) (operation . ,operation)
            (ms . ,(* 1000 (- (float-time) start)))) neo-git-compare-samples)))

(defun neo-git-compare-neo-owner (root)
  (get-buffer (format "*Neo Git: %s*" (directory-file-name root))))

(defun neo-git-compare-select-neo (root path)
  (pop-to-buffer (neo-git-compare-neo-owner root))
  (goto-char (point-min))
  (let (found)
    (while (and (not found) (< (point) (point-max)))
      (setq found (equal path (plist-get (neo-git--entry-at-point) :path)))
      (unless found (forward-line)))
    (unless found (error "Neo Git row missing: %s" path)))
  (neo-git--sync-window-point)
  (neo-git--preview-selected))

(defun neo-git-compare-select-magit (path &optional hunk)
  (goto-char (point-min))
  (let (found)
    (while (and (not found) (< (point) (point-max)))
      (let ((section (magit-current-section)))
        (setq found (and section (eq (oref section type) 'file)
                         (equal (oref section value) path))))
      (unless found (forward-line)))
    (unless found (error "Magit row missing: %s" path)))
  (magit-section-show (magit-current-section))
  (when hunk
    (forward-line)
    (let (found)
      (while (and (not found) (< (point) (point-max)))
        (setq found (eq (oref (magit-current-section) type) 'hunk))
        (unless found (forward-line)))
      (unless found (error "Magit hunk missing: %s" path))
      (magit-section-show (magit-current-section)))))

(defun neo-git-compare-file-hash (file)
  (when (and file (file-readable-p file))
    (with-temp-buffer
      (insert-file-contents-literally file)
      (secure-hash 'sha256 (current-buffer)))))

(defun neo-git-compare-run ()
  (unless (and (display-graphic-p) (not noninteractive))
    (error "This benchmark requires a GUI Emacs"))
  (unless neo-git-compare-output (error "Set NEO_GIT_COMPARE_OUTPUT"))
  ;; A fixed frame permits Neo Git's simultaneous panes and gives both tools
  ;; the same redisplay area; retain the user's fonts, theme and other config.
  (set-frame-size (selected-frame) 160 45)
  (when neo-git-compare-package-directory
    (dolist (directory (directory-files neo-git-compare-package-directory t "^[^.].*"))
      (when (file-directory-p directory) (add-to-list 'load-path directory))))
  (load neo-git-compare-source nil t)
  (require 'magit)
  (let* ((root (file-name-as-directory (make-temp-file "neo-git-compare-" t)))
         (default-directory root)
         (process-environment (copy-sequence process-environment))
         (initial-windows (current-window-configuration))
         (gc-start gcs-done))
    (setenv "GIT_CONFIG_GLOBAL" (expand-file-name "global-config" root))
    (setenv "GIT_CONFIG_NOSYSTEM" "1")
    (unwind-protect
        (progn
          (neo-git-compare-git "init" "-q" "-b" "main")
          (neo-git-compare-git "config" "user.name" "GUI Benchmark")
          (neo-git-compare-git "config" "user.email" "benchmark@example.invalid")
          (dotimes (i neo-git-compare-files)
            (with-temp-file (format "file-%03d.txt" i)
              (dotimes (line 100) (insert (format "line %d\n" line)))))
          (neo-git-compare-git "add" ".")
          (neo-git-compare-git "commit" "-qm" "baseline")
          (dotimes (i 40)
            (with-temp-file (format "file-%03d.txt" i)
              (dotimes (line 100)
                (insert (format "%s %d\n" (if (memq line '(10 50 90)) "changed" "line") line)))))
          (setq neo-git-compare-samples nil)
          ;; First openings include tool UI setup, with package loading outside
          ;; this endpoint. Subsequent iterations alternate the order of tools.
          (neo-git-compare-measure "neo-git" "first-open" #'neo-git-status
                                   (lambda () (neo-git-compare-neo-ready root)))
          (let (magit-buffer)
            (neo-git-compare-measure "magit" "first-open"
                                     (lambda () (setq magit-buffer (magit-status-setup-buffer root)))
                                     (lambda () (buffer-live-p magit-buffer)))
            (dotimes (iteration neo-git-compare-count)
              (dolist (tool (if (cl-evenp iteration) '(neo-git magit) '(magit neo-git)))
                (let* ((neo (eq tool 'neo-git))
                       (name (symbol-name tool))
                       (ready (if neo (lambda () (neo-git-compare-neo-ready root)) (lambda () t))))
                  (neo-git-compare-git "reset" "-q" "HEAD" "--" "file-000.txt")
                  (if neo
                      (progn
                        (neo-git--layout (neo-git-compare-neo-owner root))
                        (neo-git-refresh)
                        (neo-git-compare-wait ready))
                    (pop-to-buffer magit-buffer)
                    (delete-other-windows)
                    (magit-refresh))
                  (neo-git-compare-measure name "refresh"
                                           (if neo #'neo-git-refresh #'magit-refresh) ready)
                  (neo-git-compare-measure name "select-file"
                                           (if neo
                                               (lambda () (neo-git-compare-select-neo root "file-001.txt"))
                                             (lambda () (neo-git-compare-select-magit "file-001.txt"))) ready)
                  ;; Select an equivalent single hunk before starting the clock.
                  (if neo
                      (progn
                        (neo-git-compare-select-neo root "file-000.txt")
                        (neo-git-compare-wait ready)
                        (neo-git-focus-diff)
                        ;; Timer-driven measurements must align current-buffer
                        ;; with the selected window after changing focus.
                        (set-buffer (window-buffer (selected-window)))
                        (goto-char (point-min))
                        (unless (re-search-forward "^@@ " nil t)
                          (error "No hunk in %s (%S), frame %sx%s, windows %S: %s"
                                 (buffer-name) major-mode (frame-width) (frame-height)
                                 (mapcar (lambda (w) (buffer-name (window-buffer w))) (window-list))
                                 (buffer-substring-no-properties (point-min) (min (point-max) 500))))
                        (beginning-of-line)
                        (with-current-buffer (neo-git-compare-neo-owner root)
                          (setq neo-git--partial-mode 'hunk)))
                    (neo-git-compare-select-magit "file-000.txt" t))
                  (neo-git-compare-measure name "stage-hunk"
                                           (if neo #'neo-git-stage-toggle #'magit-stage) ready)
                  (unless (string-match-p "changed 10" (neo-git-compare-git "diff" "--cached"))
                    (error "%s did not stage the intended first hunk" name))
                  (when (string-match-p "changed 50" (neo-git-compare-git "diff" "--cached"))
                    (error "%s staged more than one hunk" name))
                  (when neo (neo-git-focus-list))))))
          (let ((coding-system-for-write 'utf-8-unix))
            (with-temp-file neo-git-compare-output
              (insert
               (json-encode
                `((endpoint . "operation invocation through async completion and forced Emacs redisplay")
                  (limitations . "excludes package loading, physical key delivery and compositor presentation; generated fixture")
                  (emacs . ,emacs-version) (git . ,(neo-git-compare-git "--version"))
                  (magit . ,(magit-version)) (graphic . t)
                  (frame . ,(vector (frame-width) (frame-height)))
                  (init_file . ,user-init-file) (init_sha256 . ,(neo-git-compare-file-hash user-init-file))
                  (neo_source_sha256 . ,(neo-git-compare-file-hash neo-git-compare-source))
                  (fixture_files . ,neo-git-compare-files) (changed_files . 40) (hunks_per_file . 3)
                  (gc_count . ,(- gcs-done gc-start))
                  (samples . ,(vconcat (nreverse neo-git-compare-samples)))))))))
      (set-window-configuration initial-windows)
      (dolist (buffer (buffer-list))
        (when (string-prefix-p root (buffer-local-value 'default-directory buffer))
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer)))
      (delete-directory root t))))

(defun neo-git-compare-main ()
  (condition-case err
      (progn (neo-git-compare-run) (kill-emacs 0))
    (error
     (when neo-git-compare-output
       (with-temp-file (concat neo-git-compare-output ".error")
         (prin1 err (current-buffer))))
     (kill-emacs 1))))

(add-hook 'emacs-startup-hook (lambda () (run-with-timer 0.5 nil #'neo-git-compare-main)))
