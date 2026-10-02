;;; benchmark-git.el --- Optional Neo Git runtime instrumentation -*- lexical-binding: t; -*-

;; Load after neo-git.el, then call `neo-git-benchmark-start'. The records measure
;; Git process and render work only; they do not measure redisplay readiness.

;;; Code:

(require 'cl-lib)
(require 'json)

(defvar neo-git-benchmark-events nil)
(defvar neo-git-benchmark-process-count 0)
(defvar neo-git-benchmark-active-processes 0)
(defvar neo-git-benchmark-max-active-processes 0)
(defvar neo-git-benchmark--id 0)
(defvar neo-git-benchmark--enabled nil)

(defun neo-git-benchmark--record-run (original directory arguments callback &optional limit stdin)
  (let* ((id (cl-incf neo-git-benchmark--id))
         (start (float-time))
         (wrapped
          (lambda (status output error-output)
            (setq neo-git-benchmark-active-processes
                  (max 0 (1- neo-git-benchmark-active-processes)))
            (push (append `((id . ,id)
                            (command . ,(format "%s" (car arguments)))
                            (elapsed_ms . ,(* 1000 (- (float-time) start)))
                            (status . ,(format "%s" status))
                            (stdout_bytes . ,(string-bytes output))
                            (stderr_bytes . ,(string-bytes error-output)))
                          (when stdin `((stdin_bytes . ,(string-bytes stdin)))))
                  neo-git-benchmark-events)
            (funcall callback status output error-output))))
    (cl-incf neo-git-benchmark-process-count)
    (cl-incf neo-git-benchmark-active-processes)
    (setq neo-git-benchmark-max-active-processes
          (max neo-git-benchmark-max-active-processes neo-git-benchmark-active-processes))
    (if stdin
        (funcall original directory arguments wrapped limit stdin)
      (funcall original directory arguments wrapped limit))))

(defun neo-git-benchmark--record-render (original &rest arguments)
  (let ((start (float-time)))
    (prog1 (apply original arguments)
      (push `((phase . "render")
              (elapsed_ms . ,(* 1000 (- (float-time) start))))
            neo-git-benchmark-events))))

(defun neo-git-benchmark-start ()
  "Start recording Neo Git process and render durations."
  (interactive)
  (unless (featurep 'neo-git)
    (user-error "Load neo-git.el before the benchmark"))
  (setq neo-git-benchmark-events nil
        neo-git-benchmark-process-count 0
        neo-git-benchmark-active-processes 0
        neo-git-benchmark-max-active-processes 0
        neo-git-benchmark--id 0)
  (unless neo-git-benchmark--enabled
    (advice-add 'neo-git--run :around #'neo-git-benchmark--record-run)
    (advice-add 'neo-git--render :around #'neo-git-benchmark--record-render)
    (setq neo-git-benchmark--enabled t)))

(defun neo-git-benchmark-stop ()
  "Stop recording Neo Git timings."
  (interactive)
  (when neo-git-benchmark--enabled
    (advice-remove 'neo-git--run #'neo-git-benchmark--record-run)
    (advice-remove 'neo-git--render #'neo-git-benchmark--record-render)
    (setq neo-git-benchmark--enabled nil)))

(defun neo-git-benchmark-write (file)
  "Write raw process/render timings to FILE as JSON."
  (interactive "FWrite Neo Git benchmark JSON: ")
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-file file
      (insert (json-encode
               `((graphic . ,(if (display-graphic-p)
                                 t
                               :json-false))
                 (frame_width . ,(frame-width))
                 (frame_height . ,(frame-height))
                 (process_calls . ,neo-git-benchmark-process-count)
                 (max_active_processes . ,neo-git-benchmark-max-active-processes)
                 (endpoint . "Git process and render function durations; excludes redisplay readiness")
                 (events . ,(vconcat (reverse neo-git-benchmark-events)))))))))

(provide 'benchmark-git)
;;; benchmark-git.el ends here
