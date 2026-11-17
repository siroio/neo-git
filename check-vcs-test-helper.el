;;; check-vcs-test-helper.el --- Isolated VCS test utilities -*- lexical-binding: t; -*-
(require 'ert)
(require 'neo-vcs)

(defun neo-vcs-test-wait (predicate)
  (let ((deadline (+ (float-time) 30)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))

(defun neo-vcs-test-request (context operation &optional target options write)
  "Exercise a real backend and asynchronous process, returning parsed data."
  (let (done result)
    (with-temp-buffer
      (neo-vcs-mode)
      (setq neo-vcs-context context)
      (neo-vcs--execute context (neo-vcs--request context operation target options)
                        (lambda (status data errors)
                          (setq result (list status data errors) done t)) write)
      (neo-vcs-test-wait (lambda () done))
      (unless (eq (car result) 0)
        (ert-fail (format "%s %s failed: %S" (plist-get context :backend) operation result)))
      (cadr result))))

(defun neo-vcs-test-cli (program &rest arguments)
  "Run an isolated setup command, preserving diagnostic output."
  (with-temp-buffer
    (let* ((coding-system-for-read 'utf-8-unix)
           (coding-system-for-write (if (eq system-type 'windows-nt)
                                        w32-system-coding-system 'utf-8-unix))
           (status (apply #'process-file program nil t nil arguments)))
      (unless (eq status 0) (ert-fail (list program arguments status (buffer-string))))
      (buffer-string))))

(defun neo-vcs-test-open (context)
  "Open the real three-pane UI and wait for backend results, then close it."
  (let ((width (frame-width)) (height (frame-height)) owner)
    (save-window-excursion
      (unwind-protect
          (progn
            (set-frame-size (selected-frame) 160 45)
            (setq owner (neo-vcs--open context))
            (neo-vcs-test-wait (lambda () (not (buffer-local-value 'neo-vcs--jobs owner))))
            (with-current-buffer owner
              (should-not neo-vcs--error)
              (should (plist-member neo-vcs--state :entries))
              (should (get-buffer-window owner))
              (should (get-buffer-window neo-vcs--history-buffer))
              (should (get-buffer-window neo-git--preview-buffer))
              (should (buffer-local-value 'buffer-read-only neo-git--preview-buffer))
              (should (eq (key-binding (kbd "x")) #'neo-vcs-action-menu))
              (neo-git-quit))
            (should-not (buffer-live-p owner)))
        (when (buffer-live-p owner) (kill-buffer owner))
        (set-frame-size (selected-frame) width height)))))

(provide 'check-vcs-test-helper)
