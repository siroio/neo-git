;;; neo-vcs.el --- Native multi-VCS interface for Neo Git -*- lexical-binding: t; coding: utf-8; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Shared asynchronous UI for jj, Mercurial, SVN and Perforce.  Git keeps
;; its existing workflow.  Backends describe commands and parse results.
;;; Code:
(require 'neo-git)
(require 'json)
(require 'rx)
(declare-function evil-define-key* "evil-core" (state keymap key def &rest bindings))
(defvar w32-system-coding-system)

(defvar neo-vcs--backends nil)
(defvar-local neo-vcs-context nil)
(defvar-local neo-vcs--state nil)
(defvar-local neo-vcs--jobs nil)
(defvar-local neo-vcs--generation 0)
(defvar-local neo-vcs--preview-generation 0)
(defvar-local neo-vcs--preview-job nil)
(defvar-local neo-vcs--preview-timer nil)
(defvar neo-vcs--status-directories nil
  "Directories already checked while parsing a single status response.")
(defvar-local neo-vcs--history nil)
(defvar-local neo-vcs--history-buffer nil)
(defvar-local neo-vcs--marked nil)
(defvar-local neo-vcs--filter nil)
(defvar-local neo-vcs--error nil)
(defvar-local neo-vcs--result nil)
(defvar-local neo-vcs--writing nil)
(defvar-local neo-vcs--closing nil)
(defvar-local neo-vcs--environment nil)
(defvar-local neo-vcs--preview-target nil)
(defvar-local neo-vcs--preview-kind nil)
(defvar-local neo-vcs--message-action nil)
(defvar-local neo-vcs--message-target nil)
(defvar-local neo-vcs--message-owner nil)
(defvar-local neo-vcs--message-options nil)

(cl-defstruct (neo-vcs--job (:constructor neo-vcs--make-job))
  owner context request callback commands outputs diagnostics process write cancelled done)

(defun neo-vcs-register-backend (name &rest properties)
  "Register NAME with its CLI and request PROPERTIES."
  (setf (alist-get name neo-vcs--backends) properties))

(defun neo-vcs--backend (name)
  (or (alist-get name neo-vcs--backends)
      (progn
        (require (intern (format "neo-vcs-%s" name)))
        (or (alist-get name neo-vcs--backends)
            (user-error "Backend %s did not register" name)))))

(defun neo-vcs--json (text)
  "Read structured TEXT without converting filenames or null values."
  (json-parse-string text :object-type 'alist :array-type 'list
                     :null-object nil :false-object nil))

(defun neo-vcs--decode-diff-paths (text file-header &rest extra-headers)
  "Decode Windows patch labels in TEXT using FILE-HEADER and EXTRA-HEADERS."
  (if (not (eq system-type 'windows-nt)) text
    (let ((coding (or (bound-and-true-p w32-system-coding-system) locale-coding-system))
          (pattern (rx-to-string `(seq bol (or (group ,file-header)
                                               (group (or "@@ " "## "))
                                               (group (or "--- " "+++ "))
                                               ,@extra-headers)
                                       (* nonl))))
          (case-fold-search nil)
          in-header)
      (with-temp-buffer
        (insert text)
        (goto-char (point-min))
        (while (re-search-forward pattern nil t)
          (when (match-beginning 1) (setq in-header t))
          (if (match-beginning 2) (setq in-header nil)
            (when (or in-header (not (match-beginning 3)))
              ;; Recover the native label bytes without decoding the UTF-8 hunks again.
              (replace-match
               (save-match-data
                 (decode-coding-string (encode-coding-string (match-string 0) 'utf-8-unix)
                                       coding))
               t t))))
        (buffer-string)))))

(defun neo-vcs--parent-inside-p (parent root)
  "Check ancestors of a lexically contained PARENT for links outside ROOT."
  (or (and neo-vcs--status-directories (gethash parent neo-vcs--status-directories))
      (let ((dir parent))
        (while (and (not (equal dir root)) (not (file-symlink-p (directory-file-name dir))))
          (setq dir (file-name-directory (directory-file-name dir))))
        (when (if (equal dir root) (file-directory-p root) (file-in-directory-p dir root))
          (when neo-vcs--status-directories (puthash parent t neo-vcs--status-directories))
          t))))

(defun neo-vcs--path (context path)
  "Validate PATH is a nonempty file path contained in CONTEXT's root."
  (let* ((root (file-name-as-directory (expand-file-name (plist-get context :root))))
         (path (if (and (stringp path) (eq system-type 'windows-nt))
                   (subst-char-in-string ?\\ ?/ path) path)))
    (unless (and (stringp path) (not (string-empty-p path))
                 (not (file-name-absolute-p path))
                 (not (string-match-p "\0" path))
                 (not (member ".." (split-string path "/" t)))
                 (not (member path '("." "./"))))
      (user-error "Invalid workspace path: %S" path))
    (let* ((absolute (expand-file-name path root))
           (leaf (directory-file-name absolute))
           (parent (file-name-directory leaf)))
      (unless (and (string-prefix-p root absolute) (> (length absolute) (length root))
                   (if (file-symlink-p leaf) (file-in-directory-p leaf root)
                     (neo-vcs--parent-inside-p parent root)))
        (user-error "Path leaves the workspace: %S" path))
      (substring absolute (length root)))))

(defun neo-vcs--paths (context entries)
  "Validate file ENTRIES and return their literal relative paths."
  (unless entries (user-error "Select at least one file"))
  (delete-dups (mapcar (lambda (entry) (neo-vcs--path context (plist-get entry :path))) entries)))

(defun neo-vcs-detect (directory)
  "Detect the nearest VCS in DIRECTORY, preferring jj when colocated.
Perforce discovery needs P4CONFIG/P4CLIENT or an explicit backend choice."
  (unless (file-remote-p directory)
    (let ((dir (file-name-as-directory (expand-file-name directory))) found parent)
      (while (and dir (not found))
        (setq found (cl-loop for (name . marker) in '((jj . ".jj") (hg . ".hg")
                                                     (svn . ".svn") (git . ".git"))
                             when (file-exists-p (expand-file-name marker dir)) return name))
        (unless found
          (let ((config (getenv "P4CONFIG")))
            (when (and config (not (string-empty-p config))
                       (file-exists-p (expand-file-name config dir)))
              (setq found 'p4))))
        (setq parent (file-name-directory (directory-file-name dir))
              dir (unless (equal parent dir) parent)))
      (or found (and (getenv "P4CLIENT") 'p4)))))

(defun neo-vcs--owner ()
  (let ((owner (if (derived-mode-p 'neo-vcs-mode) (current-buffer) neo-git--diff-owner)))
    (unless (and (buffer-live-p owner)
                 (buffer-local-value 'neo-vcs-context owner))
      (user-error "Open a Neo VCS workspace first"))
    owner))

(defun neo-vcs--parse-status (context parse outputs)
  ;; Share parent checks only within this snapshot.  Preview and write
  ;; operations revalidate paths against the filesystem at the time of use.
  (let* ((neo-vcs--status-directories (make-hash-table :test #'equal))
         (state (funcall parse outputs)))
    (unless (plist-member state :entries) (error "Malformed status response"))
    (dolist (entry (plist-get state :entries))
      (unless (and (plist-get entry :root-entry) (equal (plist-get entry :path) "."))
        (neo-vcs--path context (plist-get entry :path))))
    state))

(defun neo-vcs--request (context operation &optional target options)
  (let ((request (funcall (plist-get (neo-vcs--backend (plist-get context :backend)) :request)
                          context operation target options)))
    (if (not (eq operation 'status)) request
      (plist-put (copy-sequence request) :parse
                 (apply-partially #'neo-vcs--parse-status context (plist-get request :parse))))))

(defun neo-vcs--finish-job (job status result diagnostic)
  (unless (neo-vcs--job-done job)
    (setf (neo-vcs--job-done job) t)
    (let ((owner (neo-vcs--job-owner job)))
      (when (buffer-live-p owner)
        (with-current-buffer owner
          (setq neo-vcs--jobs (delq job neo-vcs--jobs))
          (unwind-protect
              (unless (neo-vcs--job-cancelled job)
                (funcall (neo-vcs--job-callback job) status result
                         (string-join (nconc (nreverse (neo-vcs--job-diagnostics job))
                                             (unless (string-empty-p diagnostic)
                                               (list diagnostic))) "\n")))
            (when (and (neo-vcs--job-write job) neo-vcs--closing (not neo-vcs--writing)
                       (not (cl-some #'neo-vcs--job-write neo-vcs--jobs)))
              (kill-buffer owner))))))))

(defun neo-vcs--job-next (job)
  (cond
   ((or (neo-vcs--job-cancelled job)
        (not (buffer-live-p (neo-vcs--job-owner job))))
    (neo-vcs--finish-job job 'cancelled nil "Cancelled"))
   ((null (neo-vcs--job-commands job))
    (let ((result
           (condition-case err
               (let* ((outputs (nreverse (neo-vcs--job-outputs job)))
                      (parse (plist-get (neo-vcs--job-request job) :parse)))
                 (list 0 (if parse (funcall parse outputs) (mapconcat #'identity outputs "")) ""))
             (error (list 'parse-error nil (error-message-string err))))))
      (apply #'neo-vcs--finish-job job result)))
   (t
    (with-current-buffer (neo-vcs--job-owner job)
      (let* ((context (neo-vcs--job-context job))
             (backend (neo-vcs--backend (plist-get context :backend)))
             (command (pop (neo-vcs--job-commands job)))
             (program (plist-get backend :program))
             (process-environment
              (append (plist-get context :environment) (plist-get backend :environment)
                      (or neo-vcs--environment process-environment)))
             (process
              (neo-git--run-command
               (plist-get context :root)
               (cons program (plist-get command :args))
               (lambda (status output errors)
                 (cond
                  ((neo-vcs--job-cancelled job)
                   (neo-vcs--finish-job job 'cancelled nil "Cancelled"))
                  ((member status (or (plist-get command :ok) '(0)))
                   (let ((diagnostic (string-trim errors))
                         (failure (condition-case err
                                      (progn
                                        (when (plist-get command :check)
                                          (funcall (plist-get command :check) output)) nil)
                                    (error (error-message-string err)))))
                     (unless (string-empty-p diagnostic)
                       (push diagnostic (neo-vcs--job-diagnostics job)))
                     (if failure (neo-vcs--finish-job job 'precondition-error nil failure)
                       (push output (neo-vcs--job-outputs job))
                       (neo-vcs--job-next job))))
                  (t (neo-vcs--finish-job
                      job status output
                      (format "%s %s\n%s" program
                              (mapconcat #'shell-quote-argument (plist-get command :args) " ")
                              (if (string-empty-p (string-trim errors))
                                  (format "%s (exit %s)" (string-trim output) status)
                                (string-trim errors)))))))
               (or (plist-get (neo-vcs--job-request job) :limit) (* 4 neo-git--limit))
               (or (plist-get command :stdin) ""))))
        (unless (neo-vcs--job-done job)
          (setf (neo-vcs--job-process job) process)
          (when (processp process)
            (process-put process 'neo-git-write (neo-vcs--job-write job)))))))))

(defun neo-vcs--execute (context request callback &optional write)
  "Run REQUEST sequentially and call CALLBACK with status, data and diagnostics.
WRITE jobs are never cancelled by refresh or buffer disposal."
  (let ((job (neo-vcs--make-job :owner (current-buffer) :context context
                               :request request :callback callback :write write
                               :commands (copy-sequence (plist-get request :commands)))))
    (push job neo-vcs--jobs)
    (neo-vcs--job-next job)
    job))

(defun neo-vcs--cancel-job (job)
  (when (and job (not (neo-vcs--job-done job)) (not (neo-vcs--job-write job)))
      (setf (neo-vcs--job-cancelled job) t)
      (when (process-live-p (neo-vcs--job-process job))
        (delete-process (neo-vcs--job-process job)))
      (neo-vcs--finish-job job 'cancelled nil "Cancelled")))

(defun neo-vcs--cancel-reads ()
  (neo-vcs--cancel-preview-timer)
  (dolist (job (copy-sequence neo-vcs--jobs)) (neo-vcs--cancel-job job)))

(defun neo-vcs--can-kill ()
  (if (or neo-vcs--writing (cl-some #'neo-vcs--job-write neo-vcs--jobs))
      (progn (setq neo-vcs--closing t)
             (message "Neo VCS: waiting for the running operation before closing") nil)
    t))

(defun neo-vcs--cleanup ()
  (setq neo-vcs--closing t)
  (cl-incf neo-vcs--generation)
  (cl-incf neo-vcs--preview-generation)
  (neo-vcs--cancel-reads)
  (dolist (buffer (buffer-list))
    (when (eq (buffer-local-value 'neo-git--diff-owner buffer) (current-buffer))
      (kill-buffer buffer))))

(defvar neo-vcs-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "j") #'neo-vcs-next)
    (define-key map (kbd "k") #'neo-vcs-previous)
    (define-key map (kbd "SPC") #'neo-vcs-mark)
    (define-key map (kbd "a") #'neo-vcs-mark-all)
    (define-key map (kbd "r") #'neo-vcs-refresh)
    (define-key map (kbd "R") #'neo-vcs-refresh)
    (define-key map (kbd "RET") #'neo-vcs-focus-diff)
    (define-key map (kbd "TAB") #'neo-vcs-focus-diff)
    (define-key map (kbd "l") #'neo-vcs-focus-history)
    (define-key map (kbd "o") #'neo-vcs-visit-file)
    (define-key map (kbd "/") #'neo-vcs-filter)
    (define-key map (kbd "x") #'neo-vcs-action-menu)
    (define-key map (kbd "?") #'neo-vcs-help)
    (define-key map (kbd "@") #'neo-vcs-log)
    (define-key map (kbd "q") #'neo-git-quit)
    map))

(define-derived-mode neo-vcs-mode tabulated-list-mode "Neo-VCS"
  "Native VCS status.  SPC marks files; x lists backend actions."
  (setq-local tabulated-list-format [("" 1 nil) ("State" 12 t) ("Group" 18 t) ("Path" 0 t)])
  (setq-local tabulated-list-padding 0)
  (setq-local truncate-lines t)
  (add-hook 'kill-buffer-query-functions #'neo-vcs--can-kill nil t)
  (add-hook 'kill-buffer-hook #'neo-vcs--cleanup nil t)
  (tabulated-list-init-header)
  (hl-line-mode 1))

(defvar neo-vcs-history-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "j") #'next-line)
    (define-key map (kbd "k") #'previous-line)
    (define-key map (kbd "RET") #'neo-vcs-show-revision)
    (define-key map (kbd "TAB") #'neo-vcs-focus-list)
    (define-key map (kbd "q") #'neo-vcs-focus-list)
    (define-key map (kbd "r") #'neo-vcs-refresh)
    (define-key map (kbd "x") #'neo-vcs-action-menu)
    map))

(define-derived-mode neo-vcs-history-mode tabulated-list-mode "Neo-VCS-History"
  "History for the attached Neo VCS workspace."
  (setq-local tabulated-list-format
              [("Revision" 16 nil) ("Author" 18 nil) ("Date" 20 nil) ("Subject" 0 nil)])
  (setq-local truncate-lines t)
  (tabulated-list-init-header)
  (hl-line-mode 1))

(defvar neo-vcs-diff-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "j") #'next-line)
    (define-key map (kbd "k") #'previous-line)
    (define-key map (kbd "TAB") #'neo-vcs-focus-list)
    (define-key map (kbd "q") #'neo-vcs-focus-list)
    (define-key map (kbd "r") #'neo-vcs-refresh)
    (define-key map (kbd "o") #'neo-vcs-visit-file)
    (define-key map (kbd "x") #'neo-vcs-action-menu)
    map))

(defun neo-vcs--display (text)
  (replace-regexp-in-string "[\n\r\t]"
                            (lambda (s) (pcase s ("\n" "\\n") ("\r" "\\r") (_ "\\t")))
                            (or text "") t t))

(defun neo-vcs--evil-bind (map)
  "Preserve MAP's pane commands in Evil normal and motion states."
  (when (fboundp 'evil-define-key*)
    ;; map-keymap also walks parent maps, visiting their bindings last.
    ;; Import only the pane's own commands, including backend action keys.
    (let ((bindings (copy-keymap map)))
      (set-keymap-parent bindings nil)
      (map-keymap (lambda (event command)
                    (when (commandp command)
                      (evil-define-key* '(normal motion) map (vector event) command)))
                  bindings))))

(with-eval-after-load 'evil
  (mapc #'neo-vcs--evil-bind
        (list neo-vcs-mode-map neo-vcs-history-mode-map neo-vcs-diff-map)))

(defun neo-vcs--visible-entries ()
  (cl-remove-if-not
   (lambda (entry) (or (not neo-vcs--filter)
                      (string-match-p neo-vcs--filter (plist-get entry :path))))
   (plist-get neo-vcs--state :entries)))

(defun neo-vcs--marked-table ()
  (let ((table (make-hash-table :test #'equal)))
    (dolist (path neo-vcs--marked) (puthash path t table))
    table))

(defun neo-vcs--render ()
  (let ((id (tabulated-list-get-id))
        (marked (neo-vcs--marked-table)))
    (when neo-vcs--marked
      (setq neo-vcs--marked
            (cl-loop for entry in (plist-get neo-vcs--state :entries)
                     for path = (plist-get entry :path)
                     when (gethash path marked) collect path)))
    (setq tabulated-list-entries
          (mapcar (lambda (entry)
                    (let ((path (plist-get entry :path)))
                      (list path (vector (if (gethash path marked) "*" "")
                                         (symbol-name (or (plist-get entry :status) 'modified))
                                         (neo-vcs--display (plist-get entry :group))
                                         (neo-vcs--display path)))))
                  (neo-vcs--visible-entries)))
    (setq header-line-format
          (neo-git--mode-line-literal
           (concat (upcase (symbol-name (plist-get neo-vcs-context :backend))) "  "
                  (neo-vcs--display (or (plist-get neo-vcs--state :label)
                                       (plist-get neo-vcs-context :label)
                                       (plist-get neo-vcs-context :root)))
                  (cond (neo-vcs--writing "  [operation running]")
                        (neo-vcs--error (concat "  ERROR: " (neo-vcs--display neo-vcs--error)))
                        (neo-vcs--result (concat "  " (neo-vcs--display neo-vcs--result)))
                        (t "  SPC: mark  x: actions  ?: help")))))
    (tabulated-list-print t)
    (when id
      (goto-char (point-min))
      (while (and (not (eobp)) (not (equal id (tabulated-list-get-id)))) (forward-line 1)))
    (when (eobp) (goto-char (point-min)))))

(defun neo-vcs--render-history ()
  (when (buffer-live-p neo-vcs--history-buffer)
    (let ((history neo-vcs--history) (error neo-vcs--error))
      (with-current-buffer neo-vcs--history-buffer
        (setq tabulated-list-entries
              (mapcar (lambda (row)
                        (list (plist-get row :id)
                              (vconcat (mapcar #'neo-vcs--display
                                               (list (or (plist-get row :short) (plist-get row :id))
                                                     (plist-get row :author) (plist-get row :date)
                                                     (plist-get row :subject)))))) history))
        (setq header-line-format
              (neo-git--mode-line-literal
               (if error (concat "History unavailable: " (neo-vcs--display error))
                 "History  RET: revision diff  TAB: files")))
        (tabulated-list-print t)))))

(defun neo-vcs--show-text (text &optional diff)
  (let ((owner (current-buffer)))
    (when (buffer-live-p neo-git--preview-buffer)
      (with-current-buffer neo-git--preview-buffer
        (let ((inhibit-read-only t))
          (neo-git--stop-refinement)
          (erase-buffer)
          (insert text)
          (if diff (progn (diff-mode) (neo-git--decorate-diff)) (special-mode))
          (setq-local neo-git--diff-owner owner)
          (use-local-map neo-vcs-diff-map)
          (setq-local buffer-read-only t)
          (dolist (mode '(diff-mode-read-only buffer-read-only))
            (setq-local minor-mode-overriding-map-alist
                        (cons (cons mode neo-vcs-diff-map)
                              (assq-delete-all mode minor-mode-overriding-map-alist))))
          (goto-char (point-min)))))))

(defun neo-vcs--error (text)
  (neo-vcs--cancel-preview-timer)
  (setq neo-vcs--error text neo-vcs--state nil neo-vcs--history nil)
  (cl-incf neo-vcs--preview-generation)
  (neo-vcs--render)
  (neo-vcs--render-history)
  (neo-vcs--show-text (concat "Unable to load workspace\n\n" text "\n\nr: retry\n")))

(defun neo-vcs-refresh ()
  "Refresh status and history without retaining stale failed results."
  (interactive)
  (with-current-buffer (neo-vcs--owner)
    (unless neo-vcs--writing
      (neo-vcs--cancel-reads)
      (let ((generation (cl-incf neo-vcs--generation))
            (owner (current-buffer)))
        (cl-incf neo-vcs--preview-generation)
        (setq neo-vcs--error nil)
        (condition-case err
            (progn
              (let ((marker (cdr (assq (plist-get neo-vcs-context :backend)
                                       '((jj . ".jj") (hg . ".hg") (svn . ".svn"))))))
                (when (and marker (not (file-exists-p
                                        (expand-file-name marker (plist-get neo-vcs-context :root)))))
                  (user-error "Workspace metadata %s is missing" marker)))
              (neo-vcs--execute
               neo-vcs-context (neo-vcs--request neo-vcs-context 'status)
               (lambda (status state errors)
                 (when (and (buffer-live-p owner) (not neo-vcs--closing)
                            (= generation neo-vcs--generation))
                   (if (not (eq status 0)) (neo-vcs--error errors)
                     (condition-case failure
                         (progn
                           (setq neo-vcs--state state)
                           (neo-vcs--render)
                           (neo-vcs--preview)
                           (neo-vcs--execute
                            neo-vcs-context (neo-vcs--request neo-vcs-context 'history)
                            (lambda (code rows message)
                              (when (and (= generation neo-vcs--generation) (not neo-vcs--closing))
                                (setq neo-vcs--history (and (eq code 0) rows))
                                (unless (eq code 0) (setq neo-vcs--error message))
                                (neo-vcs--render-history)))))
                       (error (neo-vcs--error (error-message-string failure)))))))))
          (error (neo-vcs--error (error-message-string err))))))))

(defun neo-vcs--entry ()
  (let ((id (tabulated-list-get-id)))
    (cl-find id (plist-get neo-vcs--state :entries)
             :key (lambda (e) (plist-get e :path)) :test #'equal)))

(defun neo-vcs--selected-entries ()
  (if neo-vcs--marked
      (let ((marked (neo-vcs--marked-table)))
        (cl-remove-if-not (lambda (e) (gethash (plist-get e :path) marked))
                          (neo-vcs--visible-entries)))
    (when-let* ((entry (neo-vcs--entry))) (list entry))))

(defun neo-vcs--preview (&optional revision)
  (neo-vcs--cancel-preview-timer)
  (neo-vcs--cancel-job neo-vcs--preview-job)
  (let* ((target (or revision (neo-vcs--entry)))
         (generation (cl-incf neo-vcs--preview-generation))
         (state-generation neo-vcs--generation))
    (setq neo-vcs--preview-target target neo-vcs--preview-kind (if revision 'revision 'file))
    (condition-case err
        (cond
         ((not target) (neo-vcs--show-text "No file selected\n"))
         ((and (not revision) (eq (plist-get target :status) 'untracked))
          (let ((file (expand-file-name (neo-vcs--path neo-vcs-context (plist-get target :path))
                                        (plist-get neo-vcs-context :root))))
            (neo-vcs--show-text
             (cond ((file-directory-p file) "[Directory; use o to browse]\n")
                   ((> (file-attribute-size (file-attributes file)) neo-git--limit)
                    "[Preview omitted: file exceeds 1 MiB]\n")
                   (t (with-temp-buffer
                        (insert-file-contents file)
                        (if (string-match-p "\0" (buffer-string)) "[Binary file]\n"
                          (buffer-string))))))))
         (t
          (let ((request (neo-vcs--request neo-vcs-context (if revision 'show 'diff) target)))
            (setq request (plist-put request :limit neo-git--limit))
            (setq neo-vcs--preview-job (neo-vcs--execute
             neo-vcs-context request
             (lambda (status output errors)
               (when (and (not neo-vcs--closing) (= generation neo-vcs--preview-generation)
                          (= state-generation neo-vcs--generation))
                 (neo-vcs--show-text (if (eq status 0) output (concat "Diff unavailable\n" errors))
                                     (eq status 0)))))))))
      (error (neo-vcs--show-text (concat "Diff unavailable\n" (error-message-string err)))))))

(defun neo-vcs--cancel-preview-timer ()
  (when neo-vcs--preview-timer
    (cancel-timer neo-vcs--preview-timer)
    (setq neo-vcs--preview-timer nil)))

(defun neo-vcs--schedule-preview ()
  (neo-vcs--cancel-preview-timer)
  (cl-incf neo-vcs--preview-generation)
  (let ((owner (current-buffer)))
    (setq neo-vcs--preview-timer
          (run-at-time 0.08 nil
                       (lambda ()
                         (when (buffer-live-p owner)
                           (with-current-buffer owner (neo-vcs--preview))))))))

(defun neo-vcs-next () (interactive) (forward-line 1) (when (eobp) (forward-line -1)) (neo-vcs--schedule-preview))
(defun neo-vcs-previous () (interactive) (forward-line -1) (neo-vcs--schedule-preview))
(defun neo-vcs-mark ()
  (interactive)
  (when-let* ((id (tabulated-list-get-id)))
    (let ((mark (not (member id neo-vcs--marked))))
      (setq neo-vcs--marked (if mark (cons id neo-vcs--marked) (delete id neo-vcs--marked)))
      (tabulated-list-set-col 0 (if mark "*" "") t))))
(defun neo-vcs-mark-all ()
  (interactive)
  (setq neo-vcs--marked (unless neo-vcs--marked
                         (mapcar (lambda (e) (plist-get e :path)) (neo-vcs--visible-entries))))
  (neo-vcs--render))
(defun neo-vcs-filter ()
  (interactive)
  (let ((text (read-string "Filter paths: ")))
    (setq neo-vcs--filter (unless (string-empty-p text) (regexp-quote text))))
  (neo-vcs--render)
  (neo-vcs--preview))

(defun neo-vcs-focus-list ()
  (interactive)
  (let* ((owner (neo-vcs--owner))
         (history-window (buffer-local-value 'neo-git--history-window owner)))
    ;; A narrow frame shares the lower pane between history and diff.
    (when (and (window-live-p history-window)
               (eq (window-buffer history-window) (buffer-local-value 'neo-git--preview-buffer owner)))
      (set-window-buffer history-window (buffer-local-value 'neo-vcs--history-buffer owner)))
    (neo-vcs--focus-pane owner (get-buffer-window owner))))

(defun neo-vcs--focus-pane (buffer window)
  (if (window-live-p window)
      (progn
        (set-window-buffer window buffer)
        (select-window window))
    (pop-to-buffer buffer)))

(defun neo-vcs-focus-diff ()
  (interactive)
  (let* ((owner (neo-vcs--owner))
         (preview (buffer-local-value 'neo-git--preview-buffer owner))
         (window (or (get-buffer-window preview)
                     (buffer-local-value 'neo-git--history-window owner))))
    (with-current-buffer owner
      (when (or neo-vcs--preview-timer (not (eq neo-vcs--preview-kind 'file))
                (not (equal neo-vcs--preview-target (neo-vcs--entry))))
        (neo-vcs--preview)))
    (neo-vcs--focus-pane preview window)))
(defun neo-vcs-focus-history ()
  (interactive)
  (let* ((owner (neo-vcs--owner))
         (history (buffer-local-value 'neo-vcs--history-buffer owner))
         (window (buffer-local-value 'neo-git--history-window owner)))
    (neo-vcs--focus-pane history window)))
(defun neo-vcs-show-revision ()
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (with-current-buffer (neo-vcs--owner)
      (let ((revision (cl-find id neo-vcs--history :key (lambda (r) (plist-get r :id)) :test #'equal)))
        (unless revision (user-error "Select a revision"))
        (neo-vcs--preview revision)))))

(defun neo-vcs-visit-file ()
  (interactive)
  (let ((from-diff (not (derived-mode-p 'neo-vcs-mode))))
    (with-current-buffer (neo-vcs--owner)
      (when (and from-diff (eq neo-vcs--preview-kind 'revision))
        (user-error "Select a working-copy file first"))
      (let ((entry (if from-diff neo-vcs--preview-target (neo-vcs--entry))))
        (unless entry (user-error "Select a file"))
        (find-file-other-window
         (expand-file-name (if (and (plist-get entry :root-entry)
                                    (equal (plist-get entry :path) ".")) "."
                            (neo-vcs--path neo-vcs-context (plist-get entry :path)))
                           (plist-get neo-vcs-context :root)))))))

(defun neo-vcs--check-unsaved (context)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and buffer-file-name (buffer-modified-p)
                 (file-in-directory-p buffer-file-name (plist-get context :root)))
        (user-error "Save or discard buffer edits first: %s" buffer-file-name)))))

(defun neo-vcs--reload-files (context)
  (dolist (buffer (buffer-list))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (and buffer-file-name (not (buffer-modified-p))
                   (file-in-directory-p buffer-file-name (plist-get context :root))
                   (file-exists-p buffer-file-name))
          (condition-case err (revert-buffer t t t)
            (error (message "Cannot reload %s: %s" buffer-file-name (error-message-string err)))))))))

(defun neo-vcs--actions ()
  (plist-get (neo-vcs--backend (plist-get neo-vcs-context :backend)) :actions))

(defun neo-vcs--mutate (action target options &optional completed)
  (when (or neo-vcs--writing neo-vcs--closing) (user-error "Wait for the current operation"))
  (neo-vcs--check-unsaved neo-vcs-context)
  (when (memq (plist-get action :target) '(files file)) (neo-vcs--paths neo-vcs-context target))
  (let ((request (neo-vcs--request neo-vcs-context (plist-get action :id) target options)))
    (when (and (or (plist-get action :destructive) (plist-get action :confirm))
               (not (yes-or-no-p
                     (format "%s (%s) in %s, target %s%s? "
                             (plist-get action :label) (plist-get neo-vcs-context :backend)
                             (plist-get neo-vcs-context :root)
                             (if target (mapconcat (lambda (e) (neo-vcs--display (plist-get e :path)))
                                                   (if (listp (car target)) target (list target)) ", ")
                               "workspace")
                             (mapconcat (lambda (key)
                                          (if (plist-get options key)
                                              (format ", %s %s" key (neo-vcs--display (plist-get options key))) ""))
                                        '(:change :revision :name :url) "")))))
      (user-error "Operation cancelled"))
    (neo-vcs--cancel-reads)
    (cl-incf neo-vcs--generation)
    (cl-incf neo-vcs--preview-generation)
    (setq neo-vcs--writing t neo-vcs--error nil neo-vcs--result nil)
    (neo-vcs--render)
    (neo-vcs--execute
     neo-vcs-context request
     (lambda (status output diagnostics)
       (setq neo-vcs--writing nil)
       (when (eq status 0)
         (let ((summary (if (string-empty-p diagnostics)
                            (if (stringp output) (string-trim output) "")
                          diagnostics)))
           (setq neo-vcs--result
                 (concat (plist-get action :label) ": "
                         (if (string-empty-p summary) "done"
                           (truncate-string-to-width summary 160 nil nil "…"))))))
       (when (plist-get action :worktree) (neo-vcs--reload-files neo-vcs-context))
       (unless neo-vcs--closing
         (if (eq status 0) (progn (neo-vcs-refresh) (message "Neo VCS %s" neo-vcs--result))
           (neo-vcs--error diagnostics)
           (message "Neo VCS %s failed: %s" (plist-get action :label) diagnostics)))
       (when completed (funcall completed status diagnostics))) t)))

(defvar neo-vcs-message-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'neo-vcs-message-finish)
    (define-key map (kbd "C-c C-k") #'kill-current-buffer)
    map))
(define-derived-mode neo-vcs-message-mode text-mode "Neo-VCS-Message"
  "Edit a VCS message.  C-c C-c runs the action; C-c C-k cancels.")

(defun neo-vcs-message-finish ()
  (interactive)
  (when buffer-read-only (user-error "Wait for the current operation"))
  (let ((owner neo-vcs--message-owner) (editor (current-buffer))
        (action neo-vcs--message-action) (target neo-vcs--message-target)
        (options (plist-put (copy-sequence neo-vcs--message-options) :message
                            (string-trim (buffer-string)))))
    (unless (buffer-live-p owner) (user-error "Workspace was closed"))
    (when (string-empty-p (plist-get options :message)) (user-error "Enter a message"))
    (setq buffer-read-only t)
    (condition-case err
        (with-current-buffer owner
          (neo-vcs--mutate
           action target options
           (lambda (status _errors)
             (when (buffer-live-p editor)
               (with-current-buffer editor
                 (setq buffer-read-only nil)
                 (when (eq status 0)
                   (set-buffer-modified-p nil)
                   (kill-buffer editor)))))))
      (error
       (when (buffer-live-p editor) (with-current-buffer editor (setq buffer-read-only nil)))
       (signal (car err) (cdr err))))))

(defun neo-vcs-action (id)
  "Run native action ID against explicitly selected files or arguments."
  (let ((origin (current-buffer)))
    (with-current-buffer (neo-vcs--owner)
      (let* ((owner (current-buffer))
             (action (cl-find id (neo-vcs--actions) :key (lambda (a) (plist-get a :id))))
             (input (plist-get action :input))
             (target
              (pcase (plist-get action :target)
                ('files
                 (when (and (not (eq origin owner)) (eq neo-vcs--preview-kind 'revision))
                   (user-error "Select working-copy files first"))
                 (or (neo-vcs--selected-entries) (user-error "Select at least one file")))
                ('file
                 (let* ((root (plist-get neo-vcs-context :root))
                        (file (read-file-name "File in this workspace: " root nil t)))
                   (unless (file-regular-p file) (user-error "Select a regular file"))
                   (let ((path (neo-vcs--path neo-vcs-context (file-relative-name file root))))
                     (list (or (cl-find path (plist-get neo-vcs--state :entries)
                                        :key (lambda (e) (plist-get e :path)) :test #'equal)
                               (list :path path))))))
                ('revision
                 (or (and (eq neo-vcs--preview-kind 'revision) neo-vcs--preview-target)
                     (user-error "Select a history revision first")))))
             (options (when (and input (not (eq input 'message)))
                        (let ((value (read-string (format "%s — %s: " (plist-get action :label) input))))
                          (when (string-empty-p (string-trim value)) (user-error "A %s is required" input))
                          (list (intern (concat ":" (symbol-name input))) value)))))
        (unless action (user-error "Unsupported action: %s" id))
        (when (plist-get action :capture-revision)
          (unless (plist-get neo-vcs--state :revision)
            (user-error "Refresh the working revision before editing a message"))
          (setq options (plist-put options :revision (plist-get neo-vcs--state :revision))))
        (if (eq input 'message)
            (let ((buffer (generate-new-buffer (format "*Neo VCS %s Message*" id))))
              (with-current-buffer buffer
                (neo-vcs-message-mode)
                (setq neo-vcs--message-owner owner neo-git--diff-owner owner
                      neo-vcs--message-action action neo-vcs--message-target target
                      neo-vcs--message-options options)
                (setq header-line-format (format "%s%s  C-c C-c: run  C-c C-k: cancel"
                                                  (plist-get action :label)
                                                  (if (plist-get options :revision)
                                                      (format " [%s]" (plist-get options :revision)) ""))))
              (pop-to-buffer buffer))
          (neo-vcs--mutate action target options))))))

(defun neo-vcs-action-menu ()
  (interactive)
  (let* ((actions (with-current-buffer (neo-vcs--owner) (neo-vcs--actions)))
         (choice (completing-read "VCS action: " (mapcar (lambda (a) (plist-get a :label)) actions) nil t)))
    (neo-vcs-action (plist-get (cl-find choice actions :key (lambda (a) (plist-get a :label)) :test #'equal) :id))))

(defun neo-vcs-help ()
  (interactive)
  (with-current-buffer (neo-vcs--owner)
    (message "SPC: mark, a: mark all, o: open, l: history, r: refresh, q: close; %s"
             (mapconcat (lambda (a) (format "%s: %s" (or (plist-get a :key) "x") (plist-get a :label)))
                        (neo-vcs--actions) "; "))))

(defun neo-vcs-log ()
  (interactive)
  (with-current-buffer (neo-vcs--owner)
    (let ((neo-git-root (plist-get neo-vcs-context :root))) (neo-git-open-log))))

(defun neo-vcs--open (context)
  (let* ((root (file-name-as-directory (expand-file-name (plist-get context :root))))
         (name (format "*Neo VCS %s: %s*" (plist-get context :backend)
                       (or (plist-get context :id) root)))
         (owner (get-buffer-create name))
         (environment (copy-sequence process-environment)))
    (with-current-buffer owner
      (when neo-vcs--closing (user-error "Wait for the workspace operation to finish"))
      (unless (derived-mode-p 'neo-vcs-mode) (neo-vcs-mode))
      (setq neo-vcs-context (plist-put context :root root) default-directory root
            neo-vcs--environment environment)
      (let ((map (copy-keymap neo-vcs-mode-map)))
        (dolist (action (neo-vcs--actions))
          (when-let* ((key (plist-get action :key)) (id (plist-get action :id)))
            (define-key map (kbd key) (lambda () (interactive) (neo-vcs-action id)))))
        (use-local-map map)
        (neo-vcs--evil-bind map))
      (unless (buffer-live-p neo-git--preview-buffer)
        (setq neo-git--preview-buffer (generate-new-buffer (concat name " Diff")))
        (neo-vcs--show-text "Loading workspace…\n"))
      (unless (buffer-live-p neo-vcs--history-buffer)
        (setq neo-vcs--history-buffer (generate-new-buffer (concat name " History")))
        (with-current-buffer neo-vcs--history-buffer
          (neo-vcs-history-mode)
          (setq neo-git--diff-owner owner)))
      (with-current-buffer neo-git--preview-buffer (setq neo-git--diff-owner owner))
      (neo-git--layout owner neo-vcs--history-buffer)
      (neo-vcs-refresh))
    owner))

;;;###autoload
(defun neo-vcs-status (&optional choose-backend)
  "Open the native VCS UI for this directory.
With prefix CHOOSE-BACKEND select Git, jj, hg, svn or p4 explicitly."
  (interactive "P")
  (when (file-remote-p default-directory) (user-error "Neo VCS currently requires a local workspace"))
  (let* ((backend (if choose-backend
                      (intern (completing-read "VCS: " '("git" "jj" "hg" "svn" "p4") nil t))
                    (or (neo-vcs-detect default-directory)
                        (intern (completing-read "VCS: " '("git" "jj" "hg" "svn" "p4") nil t)))))
         (context (list :backend backend :root (file-name-as-directory (expand-file-name default-directory)))))
    (if (eq backend 'git) (neo-git--status-git)
      (neo-vcs--execute context (neo-vcs--request context 'root)
                        (lambda (status result errors)
                          (if (eq status 0) (neo-vcs--open result)
                            (message "Neo VCS: %s" errors)))))))

(provide 'neo-vcs)
;;; neo-vcs.el ends here
