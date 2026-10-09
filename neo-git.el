;;; neo-git.el --- A small asynchronous Git status UI -*- lexical-binding: t; coding: utf-8; -*-

;; Author: siroio <74674262+siroio@users.noreply.github.com>
;; Maintainer: siroio <74674262+siroio@users.noreply.github.com>
;; URL: https://github.com/siroio/neo-git
;; Version: 0.3
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, vc
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A compact file-level Git interface with asynchronous status and diff panes.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'diff-mode)
(require 'hl-line)
(require 'tabulated-list)

(defvar server-buffer-clients)
(defvar server-clients)
(defvar server-process)
(defvar server-name)
(defvar server-use-tcp)
(defvar server-auth-dir)
(defvar server-socket-dir)
(declare-function server-running-p "server" (&optional name))
(declare-function server-edit "server" (&optional arg))
(declare-function server-edit-abort "server" ())
(declare-function smerge-next "smerge-mode" (&optional arg))
(declare-function smerge-prev "smerge-mode" (&optional arg))
(declare-function smerge-keep-upper "smerge-mode" ())
(declare-function smerge-keep-lower "smerge-mode" ())
(declare-function smerge-keep-all "smerge-mode" ())

;;; Buffer state

(defgroup neo-git nil "A small Git status interface."
  :group 'tools)
(defface neo-git-staged-face '((t (:inherit success)))
  "Face for staged paths and their state labels."
  :group 'neo-git)
(defface neo-git-unstaged-face '((t (:inherit warning)))
  "Face for unstaged paths and their state labels."
  :group 'neo-git)
(defface neo-git-untracked-face '((t (:inherit font-lock-type-face)))
  "Face for untracked paths and their state labels."
  :group 'neo-git)
(defface neo-git-conflict-face '((t (:inherit error)))
  "Face for conflicted paths and their state labels."
  :group 'neo-git)
(defface neo-git-branch-face '((t (:inherit font-lock-function-name-face :weight bold)))
  "Face for the current branch in the Neo Git header."
  :group 'neo-git)
(defconst neo-git--limit (* 1024 1024))
(defvar-local neo-git-root nil)
(defvar-local neo-git-state nil)
(defvar-local neo-git-entries nil)
(defvar-local neo-git--refresh-process nil)
(defvar-local neo-git--refresh-timer nil)
(defvar-local neo-git--refresh-pending nil)
(defvar-local neo-git--refresh-generation 0)
(defvar-local neo-git--diff-process nil)
(defvar-local neo-git--preview-cache nil)
(defvar-local neo-git--attributes-process nil)
(defvar-local neo-git--attributes-ready nil)
(defvar-local neo-git--attributes-file nil)
(defvar-local neo-git--diff-generation 0)
(defvar-local neo-git--mutation nil)
(defvar-local neo-git--mutation-label nil)
(defvar-local neo-git--mutation-process nil)
(defvar-local neo-git--progress-timer nil)
(defvar-local neo-git--progress-start nil)
(defvar-local neo-git--progress-detail nil)
(defvar-local neo-git--status-updating nil)
(defvar-local neo-git--partial-operation nil)
(defvar-local neo-git--last-error nil)
(defvar-local neo-git--editor-directory nil)
(defvar-local neo-git--browser-kind nil)
(defvar-local neo-git--preview-buffer nil)
(defvar-local neo-git--preview-window nil)
(defvar-local neo-git--history-window nil)
(defvar-local neo-git--window-config nil)
(defvar-local neo-git--narrow nil)
(defvar-local neo-git--current-selection nil)
(defvar-local neo-git--visual-inclusive nil)
(defvar-local neo-git--closed nil)
(defvar-local neo-git--diff-owner nil)
(defvar-local neo-git--diff-source nil)
(defvar-local neo-git--diff-id nil)
(defvar-local neo-git--diff-generation nil)
(defvar-local neo-git--diff-updating nil)
(defvar-local neo-git--diff-visual-inclusive nil)
(defvar-local neo-git--partial-mode 'line)
(defvar-local neo-git--stage-prefetch nil)
;; ponytail: a same-key install keeps the cached Git until it disappears; restart Emacs or add explicit PATH-change invalidation if live replacement matters.
(defvar neo-git--executable-cache-key nil)
(defvar neo-git--executable-cache nil)
(defvar neo-git--command-logs (make-hash-table :test #'equal))
(defconst neo-git--log-limit 80)
(defconst neo-git--log-text-limit 4096)
(defconst neo-git--stderr-limit (* 64 1024))
(defvar neo-git--interactive-editor nil
  "Editor command for an explicitly interactive Git operation.")

;;; Git executable and asynchronous processes

(defun neo-git--executable ()
  "Return the native Git executable, resolving again when its search context changes."
  (let ((key (list (copy-tree exec-path) (copy-tree exec-suffixes) default-directory)))
    (if (and neo-git--executable-cache
             (equal key neo-git--executable-cache-key)
             (file-executable-p neo-git--executable-cache))
        neo-git--executable-cache
      (let* ((git (executable-find "git"))
             (native (and git (eq system-type 'windows-nt)
                          (expand-file-name "../mingw64/bin/git.exe"
                                            (file-name-directory git))))
             (resolved (or (and native (file-executable-p native) native) git)))
        (setq neo-git--executable-cache-key nil
              neo-git--executable-cache nil)
        (if resolved
            (progn
              (setq neo-git--executable-cache-key key
                    neo-git--executable-cache resolved)
              resolved)
          (user-error "Git executable was not found"))))))

(defun neo-git--log-key (directory)
  (let ((path (file-name-as-directory (expand-file-name directory))))
    (if (eq system-type 'windows-nt) (downcase path) path)))

(defun neo-git--log-text (text)
  (let ((text (or text "")))
    (if (> (length text) neo-git--log-text-limit)
        (let* ((marker "\n[log middle omitted]\n")
               (edge (/ (- neo-git--log-text-limit (length marker)) 2)))
          (concat (substring text 0 edge)
                  marker
                  (substring text (- edge))))
      text)))

(defun neo-git--log-start (directory arguments)
  (let* ((key (neo-git--log-key directory))
         (entry (list :started (float-time) :finished nil :elapsed nil
                      :arguments (copy-sequence arguments)
                      :status 'running :stdout "" :stderr ""))
         (entries (cons entry (gethash key neo-git--command-logs))))
    (puthash key (cl-subseq entries 0 (min neo-git--log-limit (length entries)))
             neo-git--command-logs)
    entry))

(defun neo-git--log-finish (entry status stdout stderr)
  (setf (plist-get entry :finished) (float-time)
        (plist-get entry :elapsed) (- (float-time) (plist-get entry :started))
        (plist-get entry :status) status
        (plist-get entry :stdout) (neo-git--log-text stdout)
        (plist-get entry :stderr) (neo-git--log-text stderr)))

(defun neo-git--run (directory arguments callback &optional limit stdin)
  "Run Git in DIRECTORY with ARGUMENTS, then call CALLBACK with status/stdout/stderr.
LIMIT bounds captured stdout; exceeding it reports `output-limit'."
  (let ((out (generate-new-buffer " *neo-git-out*"))
        (err (generate-new-buffer " *neo-git-err*"))
        (max-output (or limit (* 16 neo-git--limit)))
        (log-entry (neo-git--log-start directory arguments))
        (finished nil)
        process)
    (cl-labels
        ((contents (buffer)
           (if (buffer-live-p buffer)
               (with-current-buffer buffer (buffer-string))
             ""))
         (dispose-buffers ()
           (when (buffer-live-p out) (kill-buffer out))
           (when (buffer-live-p err) (kill-buffer err)))
         (finish (status)
           (unless finished
             (setq finished t)
             (let ((stdout (contents out))
                   (stderr (contents err)))
               (neo-git--log-finish log-entry status stdout stderr)
               (dispose-buffers)
               (funcall callback status stdout stderr))))
         (sentinel (proc _event)
           (when (memq (process-status proc) '(exit signal))
             (finish (if (process-get proc 'neo-git-too-large)
                         'output-limit
                       (process-exit-status proc)))))
         (filter (proc chunk)
           (let ((buffer (process-buffer proc)))
             (when (buffer-live-p buffer)
               (let ((bytes (+ (or (process-get proc 'neo-git-bytes) 0)
                               (string-bytes chunk))))
                 (if (> bytes max-output)
                     (progn
                       (process-put proc 'neo-git-too-large t)
                       (delete-process proc))
                   (process-put proc 'neo-git-bytes bytes)
                   (with-current-buffer buffer
                     (goto-char (point-max))
                     (insert chunk))))))))
      (condition-case failure
          (let ((process-environment
                 (cons (concat "GIT_EDITOR=" (or neo-git--interactive-editor "true"))
                       process-environment)))
            ;; Ordinary operations keep Git's prepared message. Interactive
            ;; operations explicitly route editing back into this Emacs.
            (setq process
                  (make-process :name "neo-git" :buffer out :stderr err
                                :command (cons (neo-git--executable)
                                               (append (list "-C" (expand-file-name directory)) arguments))
                                :connection-type 'pipe :noquery t
                                :coding (if (eq system-type 'windows-nt)
                                            (cons 'utf-8-unix
                                                  (or (and (boundp 'w32-system-coding-system)
                                                           w32-system-coding-system)
                                                      locale-coding-system))
                                          'utf-8-unix)
                                :filter #'filter :sentinel #'sentinel))
            ;; On Windows the process creation coding also encodes argv.  Once
            ;; Git has started, communicate with its UTF-8 output/input stream.
            (set-process-coding-system process 'utf-8-unix 'utf-8-unix)
            (process-put process 'neo-git-stderr-buffer err)
            (process-put process 'neo-git-log-entry log-entry)
            (when stdin
              (process-send-string process stdin)
              (process-send-eof process))
            process)
        (error
         (unless finished
           (setq finished t)
           (when (process-live-p process)
             (delete-process process))
           (let ((stdout (contents out))
                 (stderr (contents err)))
             (neo-git--log-finish log-entry failure stdout stderr)
             (dispose-buffers)
             (funcall callback failure stdout
                      (if (string-empty-p stderr)
                          (error-message-string failure)
                        stderr))))
         nil)))))

(defun neo-git--root (directory callback)
  "Asynchronously find DIRECTORY's Git root and pass it to CALLBACK."
  (neo-git--run directory '("rev-parse" "--show-toplevel")
                (lambda (status output error-output)
                  (if (and (integerp status) (zerop status))
                      (funcall callback (file-name-as-directory
                                         (string-trim-right output "[\r\n]+")) nil)
                    (funcall callback nil
                             (if (string-empty-p error-output)
                                 "This directory is not inside a Git repository"
                               (string-trim error-output)))))))

;;; Porcelain status parsing

(defun neo-git--split-fields (record separators)
  "Split RECORD at exactly SEPARATORS spaces, leaving its path intact."
  (let ((start 0)
        fields)
    (dotimes (_ separators)
      (let ((space (string-match " " record start)))
        (unless space
          (error "Malformed porcelain record: %S" record))
        (push (substring record start space) fields)
        (setq start (1+ space))))
    (cons (nreverse fields) (substring record start))))

(defun neo-git--parse-status (output)
  "Parse porcelain v2 NUL-separated OUTPUT into a state plist."
  (let ((records (split-string output "\0" t))
        branch
        upstream
        oid
        ahead
        behind
        entries)
    (while records
      (let ((record (pop records)))
        (cond
         ((string-prefix-p "# branch.head " record)
          (setq branch (substring record 14)
                branch (unless (equal branch "(detached)")
                         branch)))
         ((string-prefix-p "# branch.upstream " record)
          (setq upstream (substring record 18)))
         ((string-prefix-p "# branch.oid " record)
          (setq oid (substring record 13)))
         ((string-prefix-p "# branch.ab " record)
          (when (string-match "# branch.ab +\\+\\([0-9]+\\) -\\([0-9]+\\)" record)
            (setq ahead (string-to-number (match-string 1 record))
                  behind (string-to-number (match-string 2 record)))))
         ((string-prefix-p "? " record)
          (push (list :path (substring record 2) :kind 'untracked) entries))
         ((string-prefix-p "u " record)
          (let ((parts (neo-git--split-fields record 10)))
            (push (list :path (cdr parts) :kind 'conflict) entries)))
         ((string-prefix-p "1 " record)
          (let ((parts (neo-git--split-fields record 8)))
            (setq entries (neo-git--status-entries (nth 1 (car parts)) (cdr parts) nil entries))))
         ((string-prefix-p "2 " record)
          (let ((parts (neo-git--split-fields record 9)))
            (setq entries (neo-git--status-entries (nth 1 (car parts)) (cdr parts)
                                                   (pop records) entries)))))))
    (list :branch branch :upstream upstream :oid oid :ahead ahead :behind behind
          :entries (nreverse entries))))

(defun neo-git--status-entries (xy path old-path entries)
  "Add entries for XY status, preserving both staged and unstaged sides."
  (let ((index (aref xy 0))
        (worktree (aref xy 1)))
    (cond
     ((memq ?U (list index worktree))
      (push (list :path path :old-path old-path :kind 'conflict) entries))
     (t
      (unless (eq index ?.)
        (push (list :path path :old-path old-path :kind 'staged) entries))
      (unless (eq worktree ?.)
        (push (list :path path :old-path old-path :kind 'unstaged) entries))))
    entries))

(defvar neo-git-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "j") #'neo-git-next)
    (define-key map (kbd "k") #'neo-git-previous)
    (define-key map (kbd "SPC") #'neo-git-stage-toggle)
    (define-key map (kbd "d") #'neo-git-discard)
    (define-key map (kbd "v") #'neo-git-visual-mark)
    (define-key map (kbd "V") #'neo-git-visual-line)
    (define-key map (kbd "a") #'neo-git-stage-all-toggle)
    (define-key map (kbd "c") #'neo-git-commit)
    (define-key map (kbd "e") #'neo-git-visit-file)
    (define-key map (kbd "RET") #'neo-git-focus-diff)
    (define-key map (kbd "TAB") #'neo-git-focus-diff)
    (define-key map (kbd "<backtab>") #'neo-git-focus-list)
    (define-key map (kbd "r") #'neo-git-refresh)
    (define-key map (kbd "R") #'neo-git-refresh)
    (define-key map (kbd "/") #'neo-git-search)
    (define-key map (kbd "f") #'neo-git-fetch)
    (define-key map (kbd "p") #'neo-git-pull)
    (define-key map (kbd "P") #'neo-git-push)
    (define-key map (kbd "@") #'neo-git-open-log)
    (define-key map (kbd "?") #'describe-mode)
    (define-key map (kbd "q") #'neo-git-quit)
    (define-key map (kbd "<escape>") #'neo-git-diff-escape)
    (define-key map (kbd ",") 'neo-leader-map)
    map))

;;; Status mode and key bindings

(define-derived-mode neo-git-mode special-mode "Neo-Git"
  "Major mode for the Neo Git status interface."
  (setq-local truncate-lines t)
  (setq-local header-line-format '(:eval (neo-git--status-header-line)))
  (add-hook 'kill-buffer-hook #'neo-git--progress-stop nil t)
  (add-hook 'kill-buffer-hook (lambda () (neo-git--clear-preview-cache t)) nil t)
  (setq-local hl-line-sticky-flag t)
  (hl-line-mode 1)
  (when (fboundp 'evil-define-key*)
    (evil-define-key* '(normal motion) neo-git-mode-map
                      (kbd "SPC") #'neo-git-stage-toggle (kbd "d") #'neo-git-discard
                      (kbd "v") #'evil-visual-char (kbd "V") #'evil-visual-line
                      (kbd "j") #'neo-git-next (kbd "k") #'neo-git-previous
                      (kbd "a") #'neo-git-stage-all-toggle (kbd "c") #'neo-git-commit
                      (kbd "e") #'neo-git-visit-file (kbd "r") #'neo-git-refresh
                      (kbd "R") #'neo-git-refresh (kbd "f") #'neo-git-fetch
                      (kbd "p") #'neo-git-pull (kbd "P") #'neo-git-push
                      (kbd "@") #'neo-git-open-log
                      (kbd "RET") #'neo-git-focus-diff (kbd "TAB") #'neo-git-focus-diff
                      (kbd "<backtab>") #'neo-git-focus-list (kbd "<escape>") #'neo-git-focus-list
                      (kbd "/") #'neo-git-search (kbd "q") #'neo-git-quit
                      (kbd "?") #'describe-mode (kbd ",") 'neo-leader-map)))

(defvar neo-git-diff-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map diff-mode-map)
    (define-key map (kbd "<escape>") #'neo-git-focus-list)
    (define-key map (kbd "TAB") #'neo-git-focus-list)
    (define-key map (kbd "<backtab>") #'neo-git-focus-list)
    (define-key map (kbd ",") 'neo-leader-map)
    (define-key map (kbd "SPC") #'neo-git--owner-stage)
    (define-key map (kbd "d") #'neo-git-discard)
    (define-key map (kbd "j") #'neo-git-diff-next-line)
    (define-key map (kbd "k") #'neo-git-diff-previous-line)
    (define-key map (kbd "J") #'neo-git--owner-next)
    (define-key map (kbd "K") #'neo-git--owner-previous)
    (define-key map (kbd "v") #'neo-git-diff-visual-mark)
    (define-key map (kbd "V") #'neo-git-diff-visual-line)
    (define-key map (kbd "a") #'neo-git--owner-toggle-partial-mode)
    (define-key map (kbd "c") #'neo-git--owner-commit)
    (define-key map (kbd "e") #'neo-git-diff-visit-line)
    (define-key map (kbd "@") #'neo-git-open-log)
    (define-key map (kbd "r") #'neo-git--owner-refresh)
    (define-key map (kbd "R") #'neo-git--owner-refresh)
    (define-key map (kbd "f") #'neo-git--owner-fetch)
    (define-key map (kbd "p") #'neo-git--owner-pull)
    (define-key map (kbd "P") #'neo-git--owner-push)
    (define-key map (kbd "q") #'neo-git-focus-list)
    map))

(with-eval-after-load 'evil
  (evil-define-key* '(normal motion) neo-git-diff-mode-map
                    (kbd "SPC") #'neo-git--owner-stage (kbd "d") #'neo-git-discard
                    (kbd "j") #'neo-git-diff-next-line (kbd "k") #'neo-git-diff-previous-line
                    (kbd "J") #'neo-git--owner-next (kbd "K") #'neo-git--owner-previous
                    (kbd "v") #'evil-visual-char (kbd "V") #'evil-visual-line
                    (kbd "a") #'neo-git--owner-toggle-partial-mode (kbd "c") #'neo-git--owner-commit
                    (kbd "e") #'neo-git-diff-visit-line (kbd "r") #'neo-git--owner-refresh
                    (kbd "R") #'neo-git--owner-refresh (kbd "f") #'neo-git--owner-fetch
                    (kbd "p") #'neo-git--owner-pull (kbd "P") #'neo-git--owner-push
                    (kbd "@") #'neo-git-open-log
                    (kbd "q") #'neo-git-focus-list (kbd "<escape>") #'neo-git-diff-escape
                    (kbd "TAB") #'neo-git-focus-list (kbd "<backtab>") #'neo-git-focus-list
                    (kbd ",") 'neo-leader-map))

(with-eval-after-load 'evil
  (evil-define-key* '(visual) neo-git-diff-mode-map
                    (kbd "SPC") #'neo-git--owner-stage))

(with-eval-after-load 'evil
  (evil-define-key* '(visual) neo-git-mode-map
                    (kbd "SPC") #'neo-git-stage-toggle (kbd "d") #'neo-git-discard)
  (evil-define-key* '(visual) neo-git-diff-mode-map
                    (kbd "SPC") #'neo-git--owner-stage (kbd "d") #'neo-git-discard))

;;; Selection and pane command routing

(defun neo-git--entry-at-point ()
  (get-text-property (line-beginning-position) 'neo-git-entry))

(defun neo-git-visual-mark ()
  "Begin a region at point for Neo Git selection."
  (interactive)
  (setq neo-git--visual-inclusive t)
  (push-mark (point) t t)
  (setq mark-active t))

(defun neo-git-visual-line ()
  "Begin a linewise region for Neo Git selection."
  (interactive)
  (setq neo-git--visual-inclusive t)
  (beginning-of-line)
  (push-mark (point) t t)
  (end-of-line)
  (setq mark-active t))

(defun neo-git--selected-entries ()
  "Return status entries touched by the active region, or the entry at point."
  (if (use-region-p)
      (let* ((evil-range (and (fboundp 'evil-visual-state-p)
                              (evil-visual-state-p)
                              (evil-visual-range)))
             (start (if evil-range
                        (evil-range-beginning evil-range)
                      (region-beginning)))
             (end (cond
                   (evil-range (evil-range-end evil-range))
                   (neo-git--visual-inclusive
                    (min (point-max) (1+ (region-end))))
                   (t (region-end))))
             (last (max start (1- end)))
             entries)
        (save-excursion
          (goto-char start)
          (beginning-of-line)
          (while (<= (point) last)
            (when-let ((entry (get-text-property (point) 'neo-git-entry)))
              (cl-pushnew entry entries :test #'equal))
            (forward-line 1)))
        (nreverse entries))
    (when-let ((entry (neo-git--entry-at-point)))
      (list entry))))

(defun neo-git--display-path (path)
  (replace-regexp-in-string
   "[\n\r\t]"
   (lambda (ch)
     (pcase ch ("\n" "\\n") ("\r" "\\r") (_ "\\t")))
   path))

(defun neo-git--sync-window-point ()
  (when-let* ((window (get-buffer-window (current-buffer))))
    (set-window-point window (point)))
  (when hl-line-mode
    (hl-line-highlight)))

(defun neo-git--owner-buffer ()
  (and (buffer-live-p neo-git--diff-owner) neo-git--diff-owner))

(defun neo-git--dispatch-owner (command)
  (interactive)
  (let ((owner (neo-git--owner-buffer)))
    (if owner
        (with-current-buffer owner
          (call-interactively command))
      (user-error "This preview is not attached to a Neo Git status buffer"))))

(defun neo-git--owner-next ()
  (interactive)
  (neo-git--dispatch-owner #'neo-git-next))

(defun neo-git--owner-previous ()
  (interactive)
  (neo-git--dispatch-owner #'neo-git-previous))

(defun neo-git--owner-stage ()
  (interactive)
  (cond
   ((derived-mode-p 'diff-mode)
    (neo-git--partial-stage-toggle))
   ((neo-git--owner-buffer)
    (user-error "Partial staging is unavailable for this preview; use the status list"))
   (t (neo-git--dispatch-owner #'neo-git-stage-toggle))))

(defun neo-git--owner-stage-all ()
  (interactive)
  (neo-git--dispatch-owner #'neo-git-stage-all-toggle))

(defun neo-git--owner-commit ()
  (interactive)
  (neo-git--dispatch-owner #'neo-git-commit))

(defun neo-git--owner-visit ()
  (interactive)
  (neo-git--dispatch-owner #'neo-git-visit-file))

(defun neo-git--owner-refresh ()
  (interactive)
  (neo-git--dispatch-owner #'neo-git-refresh))

(defun neo-git--owner-fetch ()
  (interactive)
  (neo-git--dispatch-owner #'neo-git-fetch))

(defun neo-git--owner-pull ()
  (interactive)
  (neo-git--dispatch-owner #'neo-git-pull))

(defun neo-git--owner-push ()
  (interactive)
  (neo-git--dispatch-owner #'neo-git-push))

(defun neo-git--owner-toggle-partial-mode ()
  (interactive)
  (if (derived-mode-p 'diff-mode)
      (neo-git--dispatch-owner #'neo-git-toggle-partial-mode)
    (user-error "Line/hunk mode is available only in a text diff")))

;;; Status rendering and refresh

(defun neo-git--visible-row-index (entry)
  (let ((kind (plist-get entry :kind))
        (index 0)
        found)
    (dolist (position (neo-git--row-positions))
      (let ((candidate (get-text-property position 'neo-git-entry)))
        (when (eq (plist-get candidate :kind) kind)
          (if (equal (plist-get candidate :path) (plist-get entry :path))
              (setq found index)
            (setq index (1+ index))))))
    found))

(defun neo-git--render (&optional selected)
  (let* ((inhibit-read-only t)
        (old (or selected (neo-git--entry-at-point)
                 (let ((group (get-text-property (line-beginning-position) 'neo-git-group)))
                   (and group (list :kind group)))))
        (old-index (and old (plist-get old :path)
                        (neo-git--visible-row-index old)))
        (old-line (line-number-at-pos))
        (groups '((unstaged . "Changes") (untracked . "Untracked")
                  (staged . "Staged") (conflict . "Conflicts")))
        target
        same-kind-target
        work-target
        empty-group-target
        nearest
        positions
        line-no
        (nearest-distance most-positive-fixnum))
    (erase-buffer)
    (insert (format "Neo Git  %s  " (or neo-git-root "")))
    (let ((branch-start (point)))
      (insert (or (plist-get neo-git-state :branch) "detached/unborn"))
      (add-text-properties branch-start (point) '(face neo-git-branch-face)))
    (insert (if (plist-get neo-git-state :upstream)
                (concat " → " (plist-get neo-git-state :upstream)) ""))
    (insert (if (integerp (plist-get neo-git-state :ahead))
                (format "  ↑%d ↓%d" (plist-get neo-git-state :ahead)
                        (plist-get neo-git-state :behind)) ""))
    (insert (if neo-git--mutation
                (format "  [%s running]" (or neo-git--mutation-label "Git operation")) ""))
    (insert (if neo-git--narrow "  [search filtered]" "") "\n\n")
    (setq line-no (line-number-at-pos))
    (dolist (group groups)
      (let* ((kind (car group))
             (items (cl-remove-if-not
                    (lambda (entry)
                      (and (eq (plist-get entry :kind) kind)
                           (or (null neo-git--narrow)
                               (string-match-p neo-git--narrow (plist-get entry :path)))))
                    neo-git-entries))
             (candidate (and items (eq kind (plist-get old :kind))
                             (nth (min (or old-index 0) (1- (length items))) items)))
             (work-candidate
              (and items
                   (pcase (plist-get old :kind)
                     ('unstaged (and (eq kind 'untracked) (car items)))
                      ('untracked (and (eq kind 'unstaged) (car (last items))))))))
        (when (or items (eq kind (plist-get old :kind)))
          (let ((header-start (point)))
            (insert (propertize (format "%s (%d)\n" (cdr group) (length items))
                                'face 'bold 'neo-git-group kind))
            (when (null items)
              (setq empty-group-target header-start)))
          (setq line-no (line-number-at-pos))
          (dolist (entry items)
            (let* ((start (point))
                   (kind (plist-get entry :kind))
                   (label (pcase kind
                            ('unstaged "UNSTAGED") ('untracked "UNTRACKED")
                            ('staged "STAGED") ('conflict "CONFLICT")))
                   (face (pcase kind
                           ('unstaged 'neo-git-unstaged-face)
                           ('untracked 'neo-git-untracked-face)
                           ('staged 'neo-git-staged-face)
                           ('conflict 'neo-git-conflict-face))))
              (insert (format "  %-9s %s%s\n" label
                              (neo-git--display-path (plist-get entry :path))
                              (if (plist-get entry :old-path)
                                  (format "  <- %s" (neo-git--display-path (plist-get entry :old-path)))
                                "")))
              (add-text-properties start (point)
                                   `(neo-git-entry ,entry neo-git-group ,kind
                                                   mouse-face highlight face ,face))
              (push start positions)
              (when (< (abs (- line-no old-line)) nearest-distance)
                (setq nearest start
                      nearest-distance (abs (- line-no old-line))))
              (when (eq entry candidate)
                (setq same-kind-target start))
              (when (eq entry work-candidate)
                (setq work-target start))
              (setq line-no (1+ line-no))
              (when (and old (equal (plist-get old :path) (plist-get entry :path))
                         (eq (plist-get old :kind) (plist-get entry :kind)))
                (setq target start)))))))
    (if (null positions)
        (insert (if neo-git--narrow
                    "No matching paths\n"
                  "Working tree clean\n"))
      (goto-char (or target same-kind-target work-target empty-group-target nearest)))
    (when (and (null positions) empty-group-target)
      (goto-char empty-group-target))
    (neo-git--sync-window-point)))

(defun neo-git--selected-id ()
  (let ((entry (neo-git--entry-at-point)))
    (and entry (list (plist-get entry :path) (plist-get entry :kind)))))

(defun neo-git-refresh ()
  "Refresh Git status immediately, coalescing requests during an active query."
  (interactive)
  (unless neo-git--closed
    (when (timerp neo-git--refresh-timer)
      (cancel-timer neo-git--refresh-timer))
    (setq neo-git--refresh-timer nil)
    (if (process-live-p neo-git--refresh-process)
        (setq neo-git--refresh-pending t)
      (neo-git--refresh-now (current-buffer)))))

(defun neo-git--refresh-result (buffer generation status output error-output &optional prefetch)
  (when (and (buffer-live-p buffer)
             (not (buffer-local-value 'neo-git--closed buffer))
             (= generation (buffer-local-value 'neo-git--refresh-generation buffer)))
    (with-current-buffer buffer
      (setq neo-git--refresh-process nil
            neo-git--status-updating nil)
      (force-mode-line-update t)
      (if neo-git--refresh-pending
          (progn
            (setq neo-git--refresh-pending nil)
            (neo-git--refresh-now buffer))
        (if (and (integerp status) (zerop status))
            (let ((state (neo-git--parse-status output))
                  (id (neo-git--selected-id))
                  (head (lambda (s) (mapcar (lambda (k) (plist-get s k))
                                            '(:oid :branch :upstream :ahead :behind)))))
              ;; Commit, pull, push, fetch and branch switches all move one of these.
              (when (and neo-git-state
                         (not (equal (funcall head neo-git-state) (funcall head state))))
                (neo-git--refresh-browsers buffer 'history))
              (setq neo-git-state state
                    neo-git-entries (plist-get state :entries))
              (neo-git--render (and id (list :path (car id) :kind (cadr id))))
              (if (and prefetch
                       (eq prefetch neo-git--stage-prefetch)
                       (= generation (plist-get prefetch :refresh-generation))
                       (= (plist-get prefetch :diff-generation) neo-git--diff-generation)
                       (null (plist-get (neo-git--entry-at-point) :old-path))
                       (equal (neo-git--selected-id) (plist-get prefetch :expected-id)))
                  (progn
                    (setq prefetch (plist-put prefetch :status-confirmed t))
                    (neo-git--stage-prefetch-publish prefetch))
                (when (eq prefetch neo-git--stage-prefetch)
                  (neo-git--invalidate-stage-prefetch))
                (neo-git--preview-selected)))
          (message "Neo Git status failed: %s"
                   (if (string-empty-p (string-trim error-output))
                       (format "Git exited with status %s" status)
                     (string-trim error-output)))
          (when (eq prefetch neo-git--stage-prefetch)
            (neo-git--invalidate-stage-prefetch)))))))

(defun neo-git--refresh-now (buffer &optional prefetch)
  (when (and (buffer-live-p buffer)
             (not (buffer-local-value 'neo-git--closed buffer)))
    (with-current-buffer buffer
      (unless prefetch
        (neo-git--invalidate-stage-prefetch))
      (setq neo-git--status-updating t)
      (neo-git--clear-preview-cache)
      (force-mode-line-update t)
      (let ((generation (cl-incf neo-git--refresh-generation)))
        (neo-git--refresh-attributes buffer generation)
        (when (timerp neo-git--refresh-timer)
          (cancel-timer neo-git--refresh-timer))
        (setq neo-git--refresh-timer nil
              neo-git--refresh-pending nil)
        (when (process-live-p neo-git--refresh-process)
          (delete-process neo-git--refresh-process))
        (when prefetch
          (setq neo-git--stage-prefetch prefetch)
          (setq prefetch (plist-put prefetch :refresh-generation generation)))
        (let ((process
               (neo-git--run neo-git-root
                             '("status" "--porcelain=v2" "-z" "--branch" "--untracked-files=all")
                             (lambda (status output error-output)
                               (neo-git--refresh-result buffer generation
                                                        status output error-output prefetch)))))
          (when (and (= generation neo-git--refresh-generation)
                     (not neo-git--closed)
                     (or (null prefetch) (eq prefetch neo-git--stage-prefetch)))
            (setq neo-git--refresh-process process)))))))

;;;###autoload
(defun neo-git-status ()
  "Open the Neo Git interface for the current repository."
  (interactive)
  (neo-git--root default-directory
                 (lambda (root error-output)
                   (if (not root)
                       (message "Neo Git: %s" error-output)
                     (let ((buffer (get-buffer-create (format "*Neo Git: %s*" (directory-file-name root)))))
                       (with-current-buffer buffer
                         (unless (derived-mode-p 'neo-git-mode)
                           (neo-git-mode))
                         (setq neo-git-root root)
                         (setq neo-git--closed nil)
                         (neo-git--render))
                       (neo-git--layout buffer)
                       (neo-git-refresh))))))

(defun neo-git--layout (buffer)
  "Show status BUFFER full-frame: list and history on the left, diff on the right."
  (with-current-buffer buffer
    (unless (get-buffer-window buffer)
      (setq neo-git--window-config (current-window-configuration))))
  ;; Popping into the current layout could land in a short bottom split.
  (select-window (or (get-largest-window nil nil t) (frame-first-window)))
  (let ((ignore-window-parameters t))
    (delete-other-windows))
  (switch-to-buffer buffer nil t)
  (neo-git--ensure-preview)
  (setq neo-git--history-window (split-window nil nil 'below))
  (set-window-buffer neo-git--history-window (neo-git--browser-buffer 'history buffer)))

;;; Diff preview and navigation

(defun neo-git--clear-preview-cache (&optional all)
  "Dispose hidden cached previews, retaining the currently displayed buffer."
  (dolist (entry neo-git--preview-cache)
    (when (and (buffer-live-p (cdr entry))
               (not (eq (cdr entry) neo-git--preview-buffer)))
      (kill-buffer (cdr entry))))
  (setq neo-git--preview-cache nil)
  (when (and all (buffer-live-p neo-git--preview-buffer))
    (kill-buffer neo-git--preview-buffer)))

(defun neo-git--set-preview-buffer (preview)
  (let ((old neo-git--preview-buffer))
    (setq neo-git--preview-buffer preview)
    (when (window-live-p neo-git--preview-window)
      (set-window-buffer neo-git--preview-window preview))
    (when (and (buffer-live-p old) (not (eq old preview))
               (not (rassq old neo-git--preview-cache)))
      (kill-buffer old))))

(defun neo-git--refresh-attributes (buffer generation)
  "Resolve the configured attributes file alongside the status query."
  (setq neo-git--attributes-ready nil)
  (when (process-live-p neo-git--attributes-process)
    (delete-process neo-git--attributes-process))
  (setq neo-git--attributes-process
        (neo-git--run
         neo-git-root '("config" "--path" "-z" "--get" "core.attributesFile")
         (lambda (status output _error)
           (when (and (buffer-live-p buffer)
                      (= generation (buffer-local-value 'neo-git--refresh-generation buffer))
                      (not (buffer-local-value 'neo-git--closed buffer)))
             (with-current-buffer buffer
               (setq neo-git--attributes-process nil
                     neo-git--attributes-ready (memq status '(0 1))
                     neo-git--attributes-file
                     (cond
                      ((and (eql status 0) (string-suffix-p (string 0) output))
                       (expand-file-name (substring output 0 -1) neo-git-root))
                      ((eql status 1)
                       (expand-file-name "git/attributes"
                                         (or (getenv "XDG_CONFIG_HOME")
                                             (expand-file-name "~/.config/"))))
                      (t (setq neo-git--attributes-ready nil))))))))))

(defun neo-git--preview-dependency-hash (file)
  "Hash FILE, distinguish absence, and reject unreadable or large files."
  (if (file-exists-p file) (neo-git--preview-file-hash file) 'absent))

(defun neo-git--preview-attributes-key (path gitdir)
  "Fingerprint worktree, common-directory and user attributes for PATH."
  (when neo-git--attributes-ready
    (let* ((common-file (expand-file-name "commondir" gitdir))
           (common (if (file-exists-p common-file)
                       (with-temp-buffer
                         (insert-file-contents common-file)
                         (expand-file-name (string-trim (buffer-string)) gitdir))
                     gitdir))
           (files (list (expand-file-name "info/attributes" common)))
           (directory (file-name-directory (expand-file-name path neo-git-root))))
      (when neo-git--attributes-file (push neo-git--attributes-file files))
      (while (and directory (file-in-directory-p directory neo-git-root))
        (push (expand-file-name ".gitattributes" directory) files)
        (setq directory (unless (equal (directory-file-name directory)
                                       (directory-file-name neo-git-root))
                          (file-name-directory (directory-file-name directory)))))
      (let ((hashes (mapcar #'neo-git--preview-dependency-hash files)))
        (when (cl-every #'identity hashes) hashes)))))

(defun neo-git--preview-file-hash (file)
  "Hash a small regular FILE, or return nil when caching is unsuitable."
  (condition-case nil
      (when (and (not (file-symlink-p file)) (file-regular-p file)
                 (<= (file-attribute-size (file-attributes file)) neo-git--limit))
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (insert-file-contents-literally file)
          (secure-hash 'sha256 (buffer-string))))
    (file-error nil)))

(defun neo-git--preview-cache-key (path kind old-path)
  "Identify an ordinary unstaged diff without starting Git.
Refresh invalidates the cache.  Content hashes also detect external edits
and index changes between refreshes, including edits with unchanged mtime."
  (when (and (eq kind 'unstaged) (not old-path)
             (not (getenv "GIT_INDEX_FILE")))
    (condition-case nil
        (let* ((dotgit (expand-file-name ".git" neo-git-root))
               (gitdir (if (file-directory-p dotgit) dotgit
                         (with-temp-buffer
                           (insert-file-contents dotgit)
                           (when (looking-at "gitdir: \\(.*\\)$")
                             (expand-file-name (string-trim (match-string 1)) neo-git-root)))))
               (file (expand-file-name path neo-git-root))
               (index-hash (and gitdir (neo-git--preview-file-hash (expand-file-name "index" gitdir))))
               (file-hash (neo-git--preview-file-hash file))
               (attributes (and gitdir (neo-git--preview-attributes-key path gitdir))))
          (when (and index-hash file-hash attributes)
            (list neo-git--refresh-generation path kind index-hash file-hash
                  (file-modes file) attributes)))
      (file-error nil))))

(defun neo-git--preview-selected ()
  (neo-git--invalidate-stage-prefetch)
  (let* ((entry (neo-git--entry-at-point))
         (buffer (current-buffer))
         (preview neo-git--preview-buffer)
         (key (and entry (neo-git--preview-cache-key
                          (plist-get entry :path) (plist-get entry :kind)
                          (plist-get entry :old-path))))
         (cached (and key (assoc key neo-git--preview-cache)))
         (generation (cl-incf neo-git--diff-generation)))
    (unless (and cached (buffer-live-p (cdr cached))
                 (with-current-buffer (cdr cached)
                   (and (derived-mode-p 'diff-mode)
                        (equal neo-git--diff-id (list (plist-get entry :path) (plist-get entry :kind)))
                        (equal neo-git--diff-source (buffer-substring-no-properties (point-min) (point-max))))))
      (setq cached nil))
    (setq neo-git--current-selection
          (and entry (list (plist-get entry :path) (plist-get entry :kind))))
    (when (process-live-p neo-git--diff-process)
      (delete-process neo-git--diff-process))
    (setq neo-git--diff-process nil)
    ;; Keep rendered hunks and their refinement overlays in cached buffers.
    ;; Never overwrite one when selecting an uncached or untracked file.
    (when (and (not cached) (buffer-live-p preview)
               (rassq preview neo-git--preview-cache))
      (setq preview (generate-new-buffer (format "*Neo Git Diff: %s*" (secure-hash 'sha1 neo-git-root))))
      (neo-git--set-preview-buffer preview))
    (if (and entry preview (buffer-live-p preview))
        (if (eq (plist-get entry :kind) 'untracked)
            (let ((file (expand-file-name (plist-get entry :path) neo-git-root)))
              (with-current-buffer preview
                (let ((inhibit-read-only t))
                  (erase-buffer)
                  (condition-case failure
                      (cond
                       ((file-directory-p file) (insert "[Directory; open with e to browse]\n"))
                       ((> (file-attribute-size (file-attributes file)) neo-git--limit)
                        (insert "[Preview omitted: file exceeds 1 MiB]\n"))
                       (t
                        (insert-file-contents file nil 0 neo-git--limit)
                        (when (string-match-p (string 0) (buffer-string))
                          (erase-buffer)
                          (insert "[Binary file preview omitted]\n"))))
                    (file-error (insert (format "[Preview unavailable: %s]\n" (error-message-string failure))))
                    (error (insert (format "[Preview unavailable: %s]\n" (error-message-string failure)))))
                  (special-mode)
                  (setq-local neo-git--diff-owner buffer)
                  (setq-local neo-git--diff-source nil
                              neo-git--diff-id nil
                              neo-git--diff-generation generation
                              neo-git--diff-updating nil
                              header-line-format '(:eval (neo-git--diff-header-line)))
                  (neo-git--use-preview-map))))
          (let ((kind (plist-get entry :kind))
                (path (plist-get entry :path))
                (old (plist-get entry :old-path)))
            (let ()
              (if cached
                  (progn
                    (setq preview (cdr cached))
                    (neo-git--set-preview-buffer preview)
                    (with-current-buffer preview
                      (setq neo-git--diff-generation generation
                            neo-git--diff-updating nil
                            mark-active nil
                            neo-git--diff-visual-inclusive nil)
                      (when (and (fboundp 'evil-visual-state-p) (evil-visual-state-p))
                        (evil-normal-state))))
                (with-current-buffer preview
                  (setq-local neo-git--diff-updating t)
                  (force-mode-line-update t))
                (setq neo-git--diff-process
                      (neo-git--run neo-git-root
                                    (neo-git--diff-arguments path kind old)
                                    (lambda (status output error-output)
                                      (when (and (buffer-live-p buffer)
                                                 (not (buffer-local-value 'neo-git--closed buffer))
                                                 (= generation (buffer-local-value 'neo-git--diff-generation buffer))
                                                 (equal (list path kind)
                                                        (buffer-local-value 'neo-git--current-selection buffer)))
                                        (with-current-buffer preview
                                          (setq neo-git--diff-updating nil))
                                        (with-current-buffer buffer
                                          (when (and key (integerp status) (zerop status)
                                                     (equal key (neo-git--preview-cache-key path kind old)))
                                            ;; At most eight 1 MiB previews per status buffer.
                                            (push (cons key preview) neo-git--preview-cache)
                                            (when (> (length neo-git--preview-cache) 8)
                                              (when (buffer-live-p (cdr (nth 8 neo-git--preview-cache)))
                                                (kill-buffer (cdr (nth 8 neo-git--preview-cache))))
                                              (setcdr (nthcdr 7 neo-git--preview-cache) nil))))
                                        (neo-git--show-diff-result buffer preview
                                                                   status output error-output
                                                                   (list path kind) generation))
                                      (when (and (buffer-live-p buffer)
                                                 (= generation (buffer-local-value 'neo-git--diff-generation buffer)))
                                        (with-current-buffer buffer
                                          (setq neo-git--diff-process nil))))
                                    neo-git--limit))))))
      (when (and preview (buffer-live-p preview))
        (with-current-buffer preview
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert "No file selected\n")
            (special-mode)
            (setq-local neo-git--diff-owner buffer)
            (setq-local neo-git--diff-source nil
                        neo-git--diff-id nil
                        neo-git--diff-generation generation
                        neo-git--diff-updating nil
                        header-line-format '(:eval (neo-git--diff-header-line)))
            (neo-git--use-preview-map))))
      (when (and (window-live-p neo-git--preview-window) preview (buffer-live-p preview))
        (set-window-buffer neo-git--preview-window preview)))))

(defun neo-git--ensure-preview ()
  (unless (buffer-live-p neo-git--preview-buffer)
    (setq neo-git--preview-buffer
          (get-buffer-create (format "*Neo Git Diff: %s*" (secure-hash 'sha1 neo-git-root)))))
  (unless (and (window-live-p neo-git--preview-window)
               (eq (window-buffer neo-git--preview-window) neo-git--preview-buffer))
    (setq neo-git--preview-window nil)
    (let ((window (get-buffer-window (current-buffer))))
      (when (and window (> (window-total-width window) 100))
        (setq neo-git--preview-window (split-window-right (max 45 (/ (window-total-width window) 2))))
        (set-window-buffer neo-git--preview-window neo-git--preview-buffer)))))

(defun neo-git--row-positions ()
  (let ((position (point-min))
        rows)
    (while (< position (point-max))
      (setq position (next-single-property-change position 'neo-git-entry nil (point-max)))
      (when (and position (< position (point-max))
                 (get-text-property position 'neo-git-entry))
        (push position rows)))
    (nreverse rows)))

(defun neo-git-next ()
  (interactive)
  (let* ((rows (neo-git--row-positions))
         (index (cl-position (line-beginning-position) rows :test #'=)))
    (when rows
      (goto-char (nth (min (1- (length rows)) (1+ (or index -1))) rows))
      (neo-git--sync-window-point)
      (neo-git--preview-selected))))

(defun neo-git-previous ()
  (interactive)
  (let* ((rows (neo-git--row-positions))
         (index (cl-position (line-beginning-position) rows :test #'=)))
    (when rows
      (goto-char (nth (max 0 (1- (or index 0))) rows))
      (neo-git--sync-window-point)
      (neo-git--preview-selected))))

(with-eval-after-load 'evil
  ;; These commands move by status row, so visual selection must retain lines.
  (evil-add-command-properties #'neo-git-next :type 'line :keep-visual t)
  (evil-add-command-properties #'neo-git-previous :type 'line :keep-visual t))

(defun neo-git-focus-diff ()
  (interactive)
  (let ((owner (or (neo-git--owner-buffer) (current-buffer))))
    (neo-git--ensure-preview)
    (if (window-live-p neo-git--preview-window)
        (select-window neo-git--preview-window)
      (let ((window (display-buffer neo-git--preview-buffer)))
        (when (buffer-live-p owner)
          (with-current-buffer owner
            (setq neo-git--preview-window window)))
        (select-window window)))))

(defun neo-git-focus-list ()
  (interactive)
  (let ((owner (or (neo-git--owner-buffer) (current-buffer))))
    (when (buffer-live-p owner)
      (if-let* ((window (get-buffer-window owner)))
          (select-window window)
        (pop-to-buffer owner)))))

(defun neo-git-diff-escape ()
  "Exit a diff selection first, then return to the status list."
  (interactive)
  (cond
   ((and (fboundp 'evil-visual-state-p) (evil-visual-state-p))
    (evil-normal-state))
   ((or mark-active neo-git--diff-visual-inclusive)
    (setq mark-active nil
          neo-git--diff-visual-inclusive nil))
   (t (neo-git-focus-list))))

(defun neo-git-visit-file ()
  (interactive)
  (let ((entry (neo-git--entry-at-point)))
    (unless entry
      (user-error "No file selected"))
    (if (eq (plist-get entry :kind) 'conflict)
        (neo-git-resolve-conflict)
      (find-file (expand-file-name (plist-get entry :path) neo-git-root)))))

(defvar-local neo-git--conflict-owner nil)
(defvar neo-git-conflict-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'neo-git-conflict-finish)
    (define-key map (kbd "C-c C-k") #'neo-git-conflict-return)
    (define-key map (kbd "C-c C-n") #'smerge-next)
    (define-key map (kbd "C-c C-p") #'smerge-prev)
    (define-key map (kbd "C-c C-m") #'smerge-keep-upper)
    (define-key map (kbd "C-c C-o") #'smerge-keep-lower)
    (define-key map (kbd "C-c C-b") #'smerge-keep-all)
    (define-key map (kbd "C-c C-e") #'smerge-ediff)
    map))

(define-minor-mode neo-git-conflict-mode
  "Resolve a Neo Git conflict with Smerge, then save and stage.
C-c C-c saves and stages; C-c C-k returns without staging.
C-c C-n/p move; C-c C-m/o/b keep upper/lower/both; C-c C-e opens Ediff."
  :lighter " Neo-Resolve" :keymap neo-git-conflict-mode-map)

(defun neo-git-resolve-conflict ()
  "Visit the selected conflict and position point at its first marker."
  (interactive)
  (let* ((owner (neo-git--status-owner))
         (entry (if (derived-mode-p 'diff-mode)
                    (with-current-buffer owner (neo-git--entry-at-point))
                  (neo-git--entry-at-point)))
         (root (buffer-local-value 'neo-git-root owner)))
    (unless (eq (plist-get entry :kind) 'conflict)
      (user-error "Select a conflicted file"))
    (let ((file (expand-file-name (plist-get entry :path) root)))
      (unless (file-regular-p file)
        (user-error "This conflict has no worktree file; resolve the deletion from Git"))
      (find-file file)
      (require 'smerge-mode)
      (setq-local neo-git--conflict-owner owner)
      (smerge-mode 1)
      (neo-git-conflict-mode 1)
      (goto-char (point-min))
      (when (re-search-forward "^<<<<<<< " nil t) (beginning-of-line))
      (message "Resolve: C-c C-m/o/b keep upper/lower/both; C-c C-c save and stage"))))

(defun neo-git-conflict-return ()
  "Return to the owning status screen without staging or discarding edits."
  (interactive)
  (unless (buffer-live-p neo-git--conflict-owner)
    (user-error "The Git status buffer is closed"))
  (pop-to-buffer neo-git--conflict-owner))

(defun neo-git-conflict-finish ()
  "Refuse unresolved markers, then save and stage only this file."
  (interactive)
  (let ((owner neo-git--conflict-owner)
        (file buffer-file-name))
    (unless (and file (buffer-live-p owner)) (user-error "No active conflict file"))
    (save-restriction
      (widen)
      (save-excursion
        (goto-char (point-min))
        (when (re-search-forward
               "^\\(?:<\\{7,\\}\\|=\\{7,\\}\\|>\\{7,\\}\\||\\{7,\\}\\)\\(?: \\|$\\)" nil t)
          (user-error "Resolve all conflict markers before staging"))))
    (when (buffer-local-value 'neo-git--mutation owner)
      (user-error "Git operation already running"))
    (save-buffer)
    (with-current-buffer owner
      (neo-git--mutate (list "add" "--" (concat ":(literal)" (file-relative-name file neo-git-root)))
                       "stage resolved conflict"))
    (neo-git-conflict-mode -1)
    (pop-to-buffer owner)))

(defun neo-git-diff-visit-line ()
  "Visit the corresponding real worktree line from the selected diff line."
  (interactive)
  (if (not (derived-mode-p 'diff-mode))
      (neo-git--owner-visit)
    (let* ((owner neo-git--diff-owner)
           (id neo-git--diff-id)
           (root (and (buffer-live-p owner)
                      (buffer-local-value 'neo-git-root owner)))
           (file (and root id (expand-file-name (car id) root))))
      (unless (and file (file-regular-p file))
        (user-error "The selected worktree file is missing; no empty file was opened"))
      ;; diff-find-source-location matches the hunk's context in the current
      ;; file, which accounts for unstaged lines before a staged hunk.
      ;; Always locate the new/worktree side, including from deleted lines.
      (let ((default-directory root))
        (let ((diff-file (diff-find-file-name nil t))
              (diff-jump-to-old-file nil))
          (unless (and diff-file
                       (file-regular-p (expand-file-name diff-file root))
                       (file-equal-p file (expand-file-name diff-file root)))
            (user-error "The diff does not identify the selected worktree file"))
          (pcase-let ((`(,source-buffer ,_offset ,position ,source-text . _)
                       (diff-find-source-location nil nil t)))
            (unless (and (buffer-live-p source-buffer) position source-text
                         (buffer-file-name source-buffer)
                         (file-equal-p file (buffer-file-name source-buffer)))
              (user-error "No matching line was found in the worktree file"))
            (pop-to-buffer source-buffer)
            (goto-char (+ (car position) (cdr source-text)))))))))

;;; Stage preview prefetch

(defun neo-git--mode-line-literal (text)
  (when text
    (replace-regexp-in-string "%" "%%" text t t)))

(defun neo-git--status-header-line ()
  (neo-git--mode-line-literal
   (cond
    (neo-git--mutation
     (format " %s  %.1fs%s"
             (or neo-git--mutation-label "Git operation")
             (if neo-git--progress-start (- (float-time) neo-git--progress-start) 0.0)
             (if neo-git--progress-detail (concat "  " neo-git--progress-detail) "")))
    (neo-git--status-updating " Updating Git status…"))))

(defun neo-git--diff-header-line ()
  (let ((owner neo-git--diff-owner))
    (neo-git--mode-line-literal
     (concat
      (when neo-git--diff-updating " Updating diff…  ")
      (when (and (buffer-live-p owner)
                 (buffer-local-value 'neo-git--mutation owner))
        (format "%s  %.1fs%s  |  "
                (or (buffer-local-value 'neo-git--mutation-label owner) "Git operation")
                (if (buffer-local-value 'neo-git--progress-start owner)
                    (- (float-time) (buffer-local-value 'neo-git--progress-start owner)) 0.0)
                (if (buffer-local-value 'neo-git--progress-detail owner)
                    (concat "  " (buffer-local-value 'neo-git--progress-detail owner))
                  "")))
      (format "Partial stage: %s mode  |  a toggles line/hunk"
              (if (and (buffer-live-p owner)
                       (eq (buffer-local-value 'neo-git--partial-mode owner) 'hunk))
                  "hunk" "line"))))))

(defun neo-git--use-preview-map ()
  (use-local-map neo-git-diff-mode-map)
  ;; diff-mode activates `diff-read-only-map' when this buffer is read-only.
  ;; Its Space binding otherwise outranks the local Neo Git map.
  (dolist (mode '(diff-mode-read-only buffer-read-only))
    (setq-local minor-mode-overriding-map-alist
                (cons (cons mode neo-git-diff-mode-map)
                      (assq-delete-all mode minor-mode-overriding-map-alist)))))

(defvar neo-git-log-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "<escape>") #'quit-window)
    map))

(with-eval-after-load 'evil
  (evil-define-key* '(normal motion) neo-git-log-mode-map
                    (kbd "q") #'quit-window
                    (kbd "<escape>") #'quit-window))

(defun neo-git-open-log ()
  "Display the bounded command and error log for this repository."
  (interactive)
  (let* ((owner (or (neo-git--owner-buffer) (current-buffer)))
         (root (and (buffer-live-p owner)
                    (buffer-local-value 'neo-git-root owner))))
    (unless root (user-error "No Neo Git repository is associated with this buffer"))
    (let ((buffer (get-buffer-create (format "*Neo Git Log: %s*" (directory-file-name root))))
          (entries (gethash (neo-git--log-key root) neo-git--command-logs)))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "Neo Git command log — %s\n\n" root))
          (if entries
              (dolist (entry (reverse entries))
                (let ((status (plist-get entry :status)))
                  (insert (format "[%s] %.3fs  git %s\n"
                                  (if (eq status 'running) "running" status)
                                  (or (plist-get entry :elapsed) 0.0)
                                  (mapconcat #'shell-quote-argument
                                             (plist-get entry :arguments) " ")))
                  (unless (string-empty-p (plist-get entry :stderr))
                    (insert (neo-git--log-text (plist-get entry :stderr)) "\n"))
                  (unless (string-empty-p (plist-get entry :stdout))
                    (insert (neo-git--log-text (plist-get entry :stdout)) "\n"))
                  (insert "\n")))
            (insert "No Git commands recorded yet.\n"))
          (special-mode)
          (use-local-map neo-git-log-mode-map)))
      (pop-to-buffer buffer))))

(defun neo-git--progress-begin ()
  (when (timerp neo-git--progress-timer)
    (cancel-timer neo-git--progress-timer))
  (setq neo-git--progress-start (float-time)
        neo-git--progress-detail nil
        neo-git--mutation-process nil
        neo-git--progress-timer
        (run-at-time 0.1 0.1 #'neo-git--progress-tick (current-buffer))))

(defun neo-git--progress-set-process (process)
  (setq neo-git--mutation-process process))

(defun neo-git--progress-stop ()
  (when (timerp neo-git--progress-timer)
    (cancel-timer neo-git--progress-timer))
  (setq neo-git--progress-timer nil
        neo-git--mutation-process nil
        neo-git--progress-start nil
        neo-git--progress-detail nil)
  (unless neo-git--closed
    (force-mode-line-update t)))

(defun neo-git--progress-tick (buffer)
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (if (or neo-git--closed (not neo-git--mutation))
          (neo-git--progress-stop)
        (let* ((process neo-git--mutation-process)
               (err (and (processp process)
                         (process-get process 'neo-git-stderr-buffer)))
               (text (and (buffer-live-p err)
                          (with-current-buffer err
                            (buffer-substring-no-properties
                             (max (point-min) (- (point-max) 4096)) (point-max))))))
          (when (and (buffer-live-p err)
                     (> (with-current-buffer err (buffer-size)) neo-git--stderr-limit))
            (with-current-buffer err
              (let* ((inhibit-read-only t)
                     (head-end (+ (point-min) 4096))
                     (tail-start (- (point-max) (- neo-git--stderr-limit 4096)))
                     (head (buffer-substring-no-properties (point-min) head-end))
                     (tail (buffer-substring-no-properties tail-start (point-max))))
                (erase-buffer)
                (insert head "\n[stderr middle omitted]\n" tail))))
          (when text
            (let* ((tail (if (> (length text) 4096) (substring text -4096) text))
                   (lines (split-string (replace-regexp-in-string "\r" "\n" tail) "\n" t))
                   (last-line (car (last lines))))
              (when (and last-line (not (string-empty-p last-line)))
                (setq neo-git--progress-detail (neo-git--log-text last-line)))))
          (force-mode-line-update t))))))

(defun neo-git--invalidate-stage-prefetch ()
  (when neo-git--stage-prefetch
    (let ((process (plist-get neo-git--stage-prefetch :diff-process)))
      (setq neo-git--stage-prefetch nil)
      (when (eq process neo-git--diff-process)
        (setq neo-git--diff-process nil)
        (when (process-live-p process)
          (delete-process process))))))

(defun neo-git--show-diff-result (owner preview status output error-output
                                        &optional id generation)
  (when (buffer-live-p preview)
    (with-current-buffer preview
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (cond ((eq status 'output-limit) "[Diff truncated at 1 MiB]\n")
                      ((and (integerp status) (zerop status)) output)
                      (t (format "[Diff failed: %s]\n" error-output))))
        (unless (derived-mode-p 'diff-mode) (diff-mode))
        (setq-local neo-git--diff-updating nil)
        (setq-local neo-git--diff-owner owner)
        (setq-local neo-git--diff-source
                    (and (integerp status) (zerop status) output))
        (setq-local neo-git--diff-id
                    (or id (and (buffer-live-p owner)
                                (buffer-local-value 'neo-git--current-selection owner))))
        (setq-local neo-git--diff-generation
                    (or generation (and (buffer-live-p owner)
                                        (buffer-local-value 'neo-git--diff-generation owner))))
        (setq-local buffer-read-only t)
        ;; diff-mode's read-only map is a minor-mode map with higher
        ;; precedence than the buffer-local map, so explicitly route it
        ;; through the Neo Git map as well.
        (setq-local header-line-format
                    '(:eval (neo-git--diff-header-line)))
        (neo-git--use-preview-map)))))

(defun neo-git-diff-next-line ()
  (interactive)
  (forward-line 1)
  (when hl-line-mode (hl-line-highlight)))

(defun neo-git-diff-visual-mark ()
  (interactive)
  (setq neo-git--diff-visual-inclusive t)
  (push-mark (point) t t)
  (setq mark-active t))

(defun neo-git-diff-visual-line ()
  (interactive)
  (setq neo-git--diff-visual-inclusive t)
  (beginning-of-line)
  (push-mark (point) t t)
  (end-of-line)
  (setq mark-active t))

(defun neo-git-diff-previous-line ()
  (interactive)
  (forward-line -1)
  (when hl-line-mode (hl-line-highlight)))

(with-eval-after-load 'evil
  (evil-add-command-properties #'neo-git-diff-next-line :type 'line :keep-visual t)
  (evil-add-command-properties #'neo-git-diff-previous-line :type 'line :keep-visual t))

(defun neo-git-toggle-partial-mode ()
  (interactive)
  (setq neo-git--partial-mode (if (eq neo-git--partial-mode 'line) 'hunk 'line))
  (message "Partial staging uses %s mode" neo-git--partial-mode))

(defun neo-git--diff-arguments (path kind &optional old-path)
  (append (list "--no-pager" "diff" "--no-ext-diff" "--no-color"
                "--no-textconv" "--src-prefix=a/" "--dst-prefix=b/" "--unified=3")
          (unless old-path (list "--no-renames"))
          (when (eq kind 'staged)
            (list "--cached"))
          (list "--" (concat ":(literal)" path))
          (when old-path
            (list (concat ":(literal)" old-path)))))

(defun neo-git--partial-hunks (text)
  "Parse one-file unified diff TEXT into headers and line-numbered hunks."
  (when (or (string-empty-p text) (> (string-bytes text) neo-git--limit))
    (user-error "Diff is empty or exceeds the 1 MiB partial-staging limit"))
  (let ((lines (split-string text "\n" nil))
        (line-number 0)
        headers hunks current)
    (when (and (string-suffix-p "\n" text) (equal (car (last lines)) ""))
      (setq lines (butlast lines)))
    (dolist (line lines)
      (setq line-number (1+ line-number))
      (cond
       ((string-match-p "^\\(?:Binary files \\|GIT binary patch\\|Submodule \\|old mode \\|new mode \\|mode change \\|rename \\|copy \\)" line)
        (user-error "This diff contains binary, rename, submodule, or mode changes"))
       ((string-match
         "^@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? +\\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@\\(.*\\)$"
         line)
        (when current
          (setq current (plist-put current :body (nreverse (plist-get current :body))))
          (push current hunks))
        (setq current
              (list :header line
                    :old-start (string-to-number (match-string 1 line))
                    :old-count (if (match-string 2 line)
                                   (string-to-number (match-string 2 line)) 1)
                    :new-start (string-to-number (match-string 3 line))
                    :new-count (if (match-string 4 line)
                                   (string-to-number (match-string 4 line)) 1)
                    :suffix (match-string 5 line)
                    :start-line line-number :end-line line-number :body nil)))
       (current
        (let ((kind (cond ((string-prefix-p " " line) 'context)
                          ((string-prefix-p "+" line) 'add)
                          ((string-prefix-p "-" line) 'delete)
                          ((string-prefix-p "\\ No newline" line) 'marker)
                          (t nil))))
          (unless kind
            (user-error "Unsupported line in unified diff: %s" line))
          (if (eq kind 'marker)
              (let ((last-token (car (plist-get current :body))))
                (unless last-token
                  (user-error "Malformed no-newline marker in diff"))
                (setcar (plist-get current :body)
                        (plist-put last-token :marker line)))
            (push (list :text line :kind kind :line line-number)
                  (plist-get current :body)))
          (setq current (plist-put current :end-line line-number))))
       (t (push line headers))))
    (when current
      (setq current (plist-put current :body (nreverse (plist-get current :body))))
      (push current hunks))
    (setq headers (nreverse headers)
          hunks (nreverse hunks))
    (unless (and (= 1 (cl-count-if (lambda (line) (string-prefix-p "diff --git " line)) headers))
                 hunks)
      (user-error "Partial staging requires one text file diff with hunks"))
    (list :headers headers :hunks hunks)))

(defun neo-git--partial-selected-lines ()
  "Return buffer line numbers selected for a partial diff operation."
  (let* ((evil-range (and (fboundp 'evil-visual-state-p)
                          (evil-visual-state-p)
                          (evil-visual-range)))
         (active (or evil-range (use-region-p)))
         (evil-type (and evil-range (fboundp 'evil-visual-type)
                         (evil-visual-type evil-visual-selection)))
         (start (if evil-range (evil-range-beginning evil-range)
                  (if active (region-beginning) (point))))
         (last-position (if active
                            (max start (if evil-range
                                           (1- (evil-range-end evil-range))
                                         (if neo-git--diff-visual-inclusive
                                             (region-end)
                                           (1- (region-end)))))
                          (point)))
         (first (line-number-at-pos start))
         (last (line-number-at-pos last-position)))
    (when (eq evil-type 'block)
      (user-error "Block visual selections cannot be partially staged"))
    (cons first last)))

(defun neo-git--partial-line-selected-p (line bounds)
  (and bounds (<= (car bounds) line) (<= line (cdr bounds))))

(defun neo-git--partial-hunk-selected-p (hunk selected-lines)
  (and selected-lines
       (<= (plist-get hunk :start-line) (cdr selected-lines))
       (>= (plist-get hunk :end-line) (car selected-lines))))

(defun neo-git--partial-render-body (body mode operation selected-lines hunk-selected)
  "Render BODY for selected lines, MODE, and OPERATION."
  (let (output)
    (dolist (token body)
      (let* ((kind (plist-get token :kind))
             (chosen (and (memq kind '(add delete))
                          (or (and (eq mode 'hunk) hunk-selected)
                              (neo-git--partial-line-selected-p
                               (plist-get token :line) selected-lines))))
             (emit (pcase operation
                     ('stage (pcase kind
                               ('context 'context)
                               ('delete (if chosen 'delete 'context))
                               ('add (and chosen 'add))))
                     ('unstage (pcase kind
                                 ('context 'context)
                                 ('delete (and chosen 'delete))
                                 ('add (if chosen 'add 'context)))))))
        (when emit
          (push (if (and (eq emit 'context)
                         (not (eq kind 'context)))
                    (concat " " (substring (plist-get token :text) 1))
                  (plist-get token :text))
                output)
          (when (plist-get token :marker)
            (push (plist-get token :marker) output)))))
    (nreverse output)))

(defun neo-git--partial-build-patch (parsed selected-lines mode operation)
  "Build a selected unified patch from PARSED for MODE and OPERATION."
  (let ((headers (plist-get parsed :headers))
        (hunks (plist-get parsed :hunks))
        (total-count 0)
        (selected-count 0)
        (delta 0)
        output)
    (dolist (hunk hunks)
      (let ((hunk-selected (neo-git--partial-hunk-selected-p hunk selected-lines)))
        (dolist (token (plist-get hunk :body))
          (when (memq (plist-get token :kind) '(add delete))
            (cl-incf total-count)
            (when (if (eq mode 'hunk)
                      hunk-selected
                    (neo-git--partial-line-selected-p
                     (plist-get token :line) selected-lines))
              (cl-incf selected-count))))))
    (unless (> selected-count 0)
      (user-error "Select a changed line or hunk"))
    (when (and (< selected-count total-count)
               (seq-some (lambda (line)
                           (or (string-prefix-p "new file mode " line)
                               (string-prefix-p "deleted file mode " line)))
                         headers))
      (user-error "Partial staging of whole-file additions/deletions is unavailable"))
    (setq output headers)
    (dolist (hunk hunks)
      (let* ((hunk-selected (neo-git--partial-hunk-selected-p hunk selected-lines))
             (body (neo-git--partial-render-body
                    (plist-get hunk :body) mode operation selected-lines hunk-selected))
            (selected-in-hunk
             (seq-some (lambda (token)
                         (and (memq (plist-get token :kind) '(add delete))
                              (or (and (eq mode 'hunk) hunk-selected)
                                  (neo-git--partial-line-selected-p
                                   (plist-get token :line) selected-lines))))
                       (plist-get hunk :body))))
        (when selected-in-hunk
          (let ((old-count 0) (new-count 0))
            (dolist (line body)
              (unless (string-prefix-p "\\ No newline" line)
                (pcase (aref line 0)
                  (32 (cl-incf old-count) (cl-incf new-count))
                  (?- (cl-incf old-count))
                  (?+ (cl-incf new-count)))))
            (let* ((source-start (if (eq operation 'stage)
                                     (plist-get hunk :old-start)
                                   (plist-get hunk :new-start)))
                   (source-count (if (eq operation 'stage) old-count new-count))
                   (target-count (if (eq operation 'stage) new-count old-count))
                   (target-start (+ source-start delta
                                    (cond ((= source-count 0) 1)
                                          ((= target-count 0) -1)
                                          (t 0))))
                   (old-start (if (eq operation 'stage) source-start target-start))
                   (new-start (if (eq operation 'stage) target-start source-start)))
              (setq output
                    (append output
                            (cons (format "@@ -%d,%d +%d,%d @@%s"
                                          old-start old-count new-start new-count
                                          (plist-get hunk :suffix))
                                  body))))
            (setq delta (+ delta (if (eq operation 'stage)
                                     (- new-count old-count)
                                   (- old-count new-count))))))))
    (unless (seq-some (lambda (line) (string-prefix-p "@@" line)) output)
      (user-error "Select a changed line or hunk"))
    (concat (mapconcat #'identity output "\n") "\n")))

(defun neo-git--partial-finish (owner token status error-output &optional refresh)
  "Finish partial Git operation TOKEN in OWNER."
  (when (and (buffer-live-p owner)
             (eq token (buffer-local-value 'neo-git--partial-operation owner)))
    (with-current-buffer owner
      (setq neo-git--partial-operation nil
            neo-git--mutation nil
            neo-git--mutation-label nil)
      (neo-git--progress-stop)
      (if (and (integerp status) (zerop status))
          (progn
            (setq neo-git--last-error nil)
            (unless neo-git--closed
              (when (fboundp 'diff-hl-update)
                (run-at-time 0 nil
                             (lambda (buffer)
                               (when (buffer-live-p buffer)
                                 (with-current-buffer buffer
                                   (diff-hl-update))))
                             owner))
              (neo-git--refresh-now owner)))
        (setq neo-git--last-error
              (if (string-empty-p (string-trim error-output))
                  (format "Git exited with status %s" status)
                (string-trim error-output)))
        (unless neo-git--closed
          (message "Neo Git partial operation failed: %s" neo-git--last-error)
          (neo-git--render))
        (when (and refresh (not neo-git--closed))
          (neo-git-refresh))))))

(defun neo-git--partial-stage-toggle (&optional discard)
  "Stage or unstage selected diff lines/hunks without touching the worktree.
With DISCARD, revert the selected unstaged lines/hunks in the worktree."
  (interactive)
  (unless (derived-mode-p 'diff-mode)
    (user-error "Open a Neo Git diff first"))
  (let* ((preview (current-buffer))
         (owner neo-git--diff-owner)
         (id neo-git--diff-id)
         (source neo-git--diff-source)
         (generation neo-git--diff-generation)
         (mode (and (buffer-live-p owner)
                    (buffer-local-value 'neo-git--partial-mode owner)))
         (selected-lines (neo-git--partial-selected-lines)))
    (unless (and (buffer-live-p owner) id source
                 (equal id (buffer-local-value 'neo-git--current-selection owner))
                 (equal source (buffer-substring-no-properties (point-min) (point-max)))
                 (= generation (buffer-local-value 'neo-git--diff-generation owner)))
      (user-error "This preview is stale; refresh it before partial staging"))
    (when (buffer-local-value 'neo-git--mutation owner)
      (user-error "Git operation already running"))
    (let* ((entry (cl-find-if
                   (lambda (candidate)
                     (and (equal (plist-get candidate :path) (car id))
                          (eq (plist-get candidate :kind) (cadr id))))
                   (buffer-local-value 'neo-git-entries owner)))
           (kind (cadr id))
           ;; Discard reverse-applies the unstage-shaped patch to the worktree.
           (operation (if (or discard (eq kind 'staged)) 'unstage 'stage)))
      (unless entry (user-error "The selected file is no longer in status"))
      (when (and discard (not (eq kind 'unstaged)))
        (user-error "Only unstaged lines can be discarded; unstage them first"))
      (when (plist-get entry :old-path)
        (user-error "Partial staging is unavailable for renamed files"))
      (when (eq kind 'untracked)
        (user-error "Stage untracked files from the status list first"))
      (when (eq kind 'conflict)
        (user-error "Resolve conflicts before staging"))
      (unless (memq kind '(staged unstaged))
        (user-error "This file cannot be partially staged"))
      (let* ((parsed (neo-git--partial-hunks source))
             (patch (neo-git--partial-build-patch parsed selected-lines mode operation))
             (token (make-symbol "neo-git-partial"))
             (root (buffer-local-value 'neo-git-root owner))
             (refresh-generation (buffer-local-value 'neo-git--refresh-generation owner)))
        (when discard
          (with-current-buffer owner (neo-git--worktree-ready))
          (unless (yes-or-no-p (format "Discard selected %s changes in %s? "
                                       mode (neo-git--display-path (car id))))
            (user-error "Discard cancelled")))
        (with-current-buffer owner
          (setq neo-git--partial-operation token
                neo-git--mutation t
                neo-git--mutation-label
                (format "%s %s: %s"
                        (cond (discard "Discard") ((eq operation 'stage) "Stage") (t "Unstage"))
                        mode
                        (neo-git--display-path (car id))))
          (neo-git--progress-begin)
          (neo-git--render))
        (when (and (fboundp 'evil-visual-state-p) (evil-visual-state-p))
          (evil-normal-state))
        (with-current-buffer preview
          (setq mark-active nil
                neo-git--diff-visual-inclusive nil))
        (let ((process
               (neo-git--run
                root (neo-git--diff-arguments (car id) kind)
                (lambda (status fresh-diff error-output)
                  (let ((valid
                         (and (buffer-live-p owner)
                              (buffer-live-p preview)
                              (not (buffer-local-value 'neo-git--closed owner))
                              (eq token (buffer-local-value 'neo-git--partial-operation owner))
                              (= generation (buffer-local-value 'neo-git--diff-generation owner))
                              (= refresh-generation
                                 (buffer-local-value 'neo-git--refresh-generation owner))
                              (equal id (buffer-local-value 'neo-git--current-selection owner))
                              (eq owner (buffer-local-value 'neo-git--diff-owner preview))
                              (equal id (buffer-local-value 'neo-git--diff-id preview))
                              (= generation (buffer-local-value 'neo-git--diff-generation preview))
                              (equal source (buffer-local-value 'neo-git--diff-source preview))
                              (with-current-buffer preview
                                (equal source
                                       (buffer-substring-no-properties
                                        (point-min) (point-max)))))))
                    (cond
                     ((not valid)
                      (neo-git--partial-finish
                       owner token 'stale "Preview or selection changed before Git apply" t))
                     ((not (and (integerp status) (zerop status)
                                (equal source fresh-diff)))
                      (neo-git--partial-finish
                       owner token
                       (if (and (integerp status) (zerop status)) 'stale status)
                       (if (and (integerp status) (zerop status))
                           "Diff changed; partial patch was not applied"
                         error-output)
                       t))
                     (t
                      (let ((apply-process
                             (neo-git--run
                              root (append '("apply" "--whitespace=nowarn")
                                           (unless discard '("--cached"))
                                           (when (eq operation 'unstage) '("--reverse")))
                              (lambda (apply-status _output apply-error)
                                (when (and discard (eq apply-status 0) (buffer-live-p owner))
                                  (with-current-buffer owner
                                    (neo-git--revert-worktree-buffers)))
                                (neo-git--partial-finish
                                 owner token apply-status apply-error))
                              neo-git--limit patch)))
                        (when (and (buffer-live-p owner)
                                   (eq token
                                       (buffer-local-value
                                        'neo-git--partial-operation owner))
                                   (process-live-p apply-process))
                          (with-current-buffer owner
                            (neo-git--progress-set-process apply-process))))))))
                neo-git--limit)))
          (when (and neo-git--mutation (process-live-p process))
            (neo-git--progress-set-process process)))))))

(defun neo-git--stage-prefetch-publish (prefetch)
  (when (and (eq prefetch neo-git--stage-prefetch)
             (plist-get prefetch :status-confirmed)
             (plist-get prefetch :diff-done)
             (= (plist-get prefetch :diff-generation) neo-git--diff-generation)
             (equal (neo-git--selected-id) (plist-get prefetch :expected-id)))
    (setq neo-git--current-selection (plist-get prefetch :expected-id))
    (neo-git--show-diff-result (current-buffer) neo-git--preview-buffer
                               (plist-get prefetch :status)
                               (plist-get prefetch :output)
                               (plist-get prefetch :error-output)
                               (plist-get prefetch :expected-id)
                               (plist-get prefetch :diff-generation))
    (setq neo-git--stage-prefetch nil
          neo-git--diff-process nil)
    (when (and (window-live-p neo-git--preview-window)
               (buffer-live-p neo-git--preview-buffer))
      (set-window-buffer neo-git--preview-window neo-git--preview-buffer))))

(defun neo-git--stage-prefetch-start (buffer hint)
  (when (and (buffer-live-p buffer)
             (not (buffer-local-value 'neo-git--closed buffer)))
    (with-current-buffer buffer
      (neo-git--invalidate-stage-prefetch)
      (cl-incf neo-git--diff-generation)
      (when (process-live-p neo-git--diff-process)
        (delete-process neo-git--diff-process))
      (let* ((path (plist-get hint :path))
             (kind (plist-get hint :kind))
             (generation neo-git--diff-generation)
             (prefetch (list :expected-id (list path kind)
                             :diff-generation generation)))
        (setq neo-git--stage-prefetch prefetch)
        (neo-git--refresh-now buffer prefetch)
        (when (eq prefetch neo-git--stage-prefetch)
          (let ((process
                 (neo-git--run neo-git-root (neo-git--diff-arguments path kind)
                               (lambda (status output error-output)
                                 (when (and (buffer-live-p buffer)
                                            (not (buffer-local-value 'neo-git--closed buffer)))
                                   (with-current-buffer buffer
                                     (when (and (eq prefetch neo-git--stage-prefetch)
                                                (= generation neo-git--diff-generation))
                                       (setq prefetch (plist-put prefetch :diff-done t))
                                       (setq prefetch (plist-put prefetch :status status))
                                       (setq prefetch (plist-put prefetch :output output))
                                       (setq prefetch (plist-put prefetch :error-output error-output))
                                       (neo-git--stage-prefetch-publish prefetch)
                                       (when (eq prefetch neo-git--stage-prefetch)
                                         (setq neo-git--diff-process nil))))))
                               neo-git--limit)))
            (when (eq prefetch neo-git--stage-prefetch)
              (setq neo-git--diff-process
                    (unless (plist-get prefetch :diff-done)
                      process))
              (setq prefetch (plist-put prefetch :diff-process neo-git--diff-process)))))))))

;;; Closing and search

(defun neo-git-quit ()
  (interactive)
  (let ((owner (current-buffer))
        (preview neo-git--preview-buffer)
        (preview-window neo-git--preview-window))
    (setq neo-git--closed t)
    (cl-incf neo-git--refresh-generation)
    (cl-incf neo-git--diff-generation)
    (when (timerp neo-git--refresh-timer)
      (cancel-timer neo-git--refresh-timer))
    (setq neo-git--refresh-timer nil
          neo-git--status-updating nil)
    (neo-git--progress-stop)
    (setq neo-git--refresh-pending nil)
    (when (process-live-p neo-git--refresh-process)
      (delete-process neo-git--refresh-process))
    (setq neo-git--refresh-process nil)
    (when (process-live-p neo-git--attributes-process)
      (delete-process neo-git--attributes-process))
    (setq neo-git--attributes-process nil)
    (neo-git--clear-preview-cache)
    (when (process-live-p neo-git--diff-process)
      (delete-process neo-git--diff-process))
    (setq neo-git--diff-process nil)
    (neo-git--invalidate-stage-prefetch)
    (setq neo-git--preview-window nil
          neo-git--history-window nil)
    (if (window-configuration-p neo-git--window-config)
        (progn
          (set-window-configuration (prog1 neo-git--window-config
                                      (setq neo-git--window-config nil)))
          (bury-buffer owner))
      (when (and (window-live-p preview-window)
                 (eq (window-buffer preview-window) preview)
                 (> (length (window-list nil 'no-minibuffer)) 1))
        (delete-window preview-window))
      (quit-window))
    ;; In a narrow layout the preview replaced the list in one window.  Its
    ;; window history can therefore make quit-window select that preview again.
    (when (and (buffer-live-p preview) (eq (current-buffer) preview))
      (bury-buffer preview)
      (when (buffer-live-p owner)
        (bury-buffer owner))
      (switch-to-buffer (other-buffer preview t)))))

(defun neo-git-search ()
  (interactive)
  (let ((query (read-string "Filter paths: ")))
    (setq neo-git--narrow (unless (string-empty-p query)
                            (regexp-quote query)))
    (neo-git--render)
    (neo-git--preview-selected)))

;;; Index changes and commit

(defun neo-git--mutate (arguments &optional label prefetch worktree)
  (when neo-git--mutation
    (user-error "Git operation already running"))
  (when worktree (neo-git--worktree-ready (eq worktree 'resume)))
  ;; A preview read started before this write must never publish against a
  ;; changed index, including when no next-file prefetch is available.
  (neo-git--invalidate-stage-prefetch)
  (cl-incf neo-git--diff-generation)
  (when (process-live-p neo-git--diff-process)
    (delete-process neo-git--diff-process))
  (setq neo-git--diff-process nil)
  (setq neo-git--mutation t)
  (setq neo-git--mutation-label (or label (car arguments)))
  (neo-git--progress-begin)
  (neo-git--render)
  (let ((buffer (current-buffer)))
    (let ((process
           (neo-git--run neo-git-root arguments
                         (lambda (status _output error-output)
                           (when (buffer-live-p buffer)
                             (with-current-buffer buffer
                               (setq neo-git--editor-directory nil)
                               (setq neo-git--mutation nil
                                     neo-git--mutation-label nil)
                               (neo-git--progress-stop)
                               (when worktree (neo-git--revert-worktree-buffers))
                               (when (or worktree (member (car arguments)
                                                          '("stash" "branch" "fetch" "pull" "push")))
                                 (neo-git--refresh-browsers buffer))
                               (unless neo-git--closed
                                 (if (and (integerp status) (zerop status))
                                     (progn
                                       (setq neo-git--last-error nil)
                                       (when (fboundp 'diff-hl-update)
                                         (run-at-time 0 nil
                                                      (lambda (target)
                                                        (when (buffer-live-p target)
                                                          (with-current-buffer target
                                                            (diff-hl-update))))
                                                      buffer))
                                       (when (timerp neo-git--refresh-timer)
                                         (cancel-timer neo-git--refresh-timer))
                                       (setq neo-git--refresh-timer nil)
                                       (if prefetch
                                           (neo-git--stage-prefetch-start buffer prefetch)
                                         (neo-git--refresh-now buffer)))
                                   (setq neo-git--last-error
                                         (if (string-empty-p (string-trim error-output))
                                             (format "Git exited with status %s" status)
                                           (string-trim error-output)))
                                   (message "Neo Git failed: %s" neo-git--last-error)
                                   (if worktree
                                       (neo-git--refresh-now buffer)
                                     (neo-git--render))))))))))
      (when (and neo-git--mutation (process-live-p process))
        (neo-git--progress-set-process process)))))

(defun neo-git--stage-label (action entries)
  (if (= (length entries) 1)
      (format "%s %s" action (neo-git--display-path (plist-get (car entries) :path)))
    (format "%s %d files" action (length entries))))

(defun neo-git--next-source-entry (entry)
  (let* ((kind (plist-get entry :kind))
         (visible (lambda (candidate)
                    (or (null neo-git--narrow)
                        (string-match-p neo-git--narrow
                                        (plist-get candidate :path)))))
         (group (seq-filter (lambda (candidate)
                              (and (eq (plist-get candidate :kind) kind)
                                   (funcall visible candidate)))
                            neo-git-entries))
         (index (cl-position entry group :test #'equal))
         (same-group (or (and index (nth (1+ index) group))
                         (and index (> index 0) (nth (1- index) group)))))
    (or same-group
        (pcase kind
          ('unstaged (car (seq-filter (lambda (candidate)
                                       (and (eq (plist-get candidate :kind) 'untracked)
                                            (funcall visible candidate)))
                                     neo-git-entries)))
          ('untracked (car (last (seq-filter (lambda (candidate)
                                               (and (eq (plist-get candidate :kind) 'unstaged)
                                                    (funcall visible candidate)))
                                             neo-git-entries))))))))

(defun neo-git--stage-entries (entries)
  (unless entries
    (user-error "Select at least one file row"))
  (let* ((kinds (mapcar (lambda (entry) (plist-get entry :kind)) entries))
         (staged (memq 'staged kinds))
         (unstaged (or (memq 'unstaged kinds) (memq 'untracked kinds) (memq 'conflict kinds)))
         (single (and (= (length entries) 1) (car entries)))
         (paths (delete-dups
                 (cl-loop for entry in entries
                          append (cons (concat ":(literal)" (plist-get entry :path))
                                        (when (and staged (plist-get entry :old-path))
                                          (list (concat ":(literal)"
                                                        (plist-get entry :old-path))))))))
         (candidate (and single (neo-git--next-source-entry single)))
         (prefetch (and candidate
                        (not (plist-get candidate :old-path))
                        (memq (plist-get candidate :kind) '(unstaged staged))
                        (not (and staged
                                  (equal (plist-get neo-git-state :oid) "(initial)")))
                        (list :path (plist-get candidate :path)
                              :kind (plist-get candidate :kind)))))
    (dolist (entry entries)
      (let ((file (expand-file-name (plist-get entry :path) neo-git-root)))
        (when (and (eq (plist-get entry :kind) 'conflict) (file-regular-p file)
                   (with-temp-buffer
                     (insert-file-contents file)
                     (re-search-forward "^\\(<<<<<<<\\|>>>>>>>\\)\\( \\|$\\)" nil t)))
          (user-error "Conflict markers remain in %s" (plist-get entry :path)))))
    (when (and staged unstaged)
      (user-error "Select staged or unstaged rows separately"))
    (cond
     (staged
      (if (and neo-git-state
               (not (equal (plist-get neo-git-state :oid) "(initial)")))
          (neo-git--mutate (append '("restore" "--staged" "--") paths)
                           (neo-git--stage-label "Unstage" entries)
                           prefetch)
        (neo-git--mutate (append '("rm" "--cached" "-f" "--") paths)
                         (neo-git--stage-label "Unstage" entries))))
     (unstaged
      (neo-git--mutate (append '("add" "--") paths)
                       (neo-git--stage-label "Stage" entries)
                       prefetch))
     (t (user-error "Selection does not contain stageable rows")))))

(defun neo-git-stage-toggle ()
  (interactive)
  (if (derived-mode-p 'diff-mode)
      (neo-git--partial-stage-toggle)
    (neo-git--stage-entries (neo-git--selected-entries))
    (if (and (fboundp 'evil-visual-state-p) (evil-visual-state-p))
        (evil-normal-state)
      (setq mark-active nil))
    (setq neo-git--visual-inclusive nil)))

(defun neo-git-discard ()
  "Discard selected worktree changes: lines/hunks in a diff, files in the list.
Unstaged files are restored from the index; untracked files are deleted."
  (interactive)
  (if (derived-mode-p 'diff-mode)
      (neo-git--partial-stage-toggle 'discard)
    (let* ((entries (or (neo-git--selected-entries)
                        (user-error "Select at least one file row")))
           (kinds (delete-dups (mapcar (lambda (entry) (plist-get entry :kind)) entries)))
           (paths (mapcar (lambda (entry) (concat ":(literal)" (plist-get entry :path)))
                          entries)))
      (unless (= (length kinds) 1)
        (user-error "Select unstaged or untracked rows separately"))
      (unless (memq (car kinds) '(unstaged untracked))
        (user-error "Only unstaged or untracked changes can be discarded"))
      (neo-git--worktree-ready)
      (unless (yes-or-no-p (format "%s? This cannot be undone. "
                                   (neo-git--stage-label
                                    (if (eq (car kinds) 'untracked) "Delete" "Discard")
                                    entries)))
        (user-error "Discard cancelled"))
      (neo-git--mutate (append (if (eq (car kinds) 'untracked)
                                   '("clean" "-f" "--")
                                 '("restore" "--worktree" "--"))
                               paths)
                       (neo-git--stage-label "Discard" entries) nil t)
      (if (and (fboundp 'evil-visual-state-p) (evil-visual-state-p))
          (evil-normal-state)
        (setq mark-active nil))
      (setq neo-git--visual-inclusive nil))))

(defun neo-git-stage-all-toggle ()
  (interactive)
  (when (seq-some (lambda (e)
                    (eq (plist-get e :kind) 'conflict)) neo-git-entries)
    (user-error "Stage resolved conflicts one by one before staging all files"))
  (if (seq-some (lambda (e)
                  (memq (plist-get e :kind) '(unstaged untracked))) neo-git-entries)
      (progn
        (neo-git--render '(:kind unstaged))
        (neo-git--mutate '("add" "-A") "Stage all files"))
    (if (and neo-git-state (not (equal (plist-get neo-git-state :oid) "(initial)")))
        (progn
          (neo-git--render '(:kind staged))
          (neo-git--mutate '("restore" "--staged" ".") "Unstage all files"))
      (progn
        (neo-git--render '(:kind staged))
        (neo-git--mutate '("rm" "--cached" "-r" "-f" ".") "Unstage all files")))))

(defvar-local neo-git--commit-kind nil)
(defvar-local neo-git--commit-head nil)

(defun neo-git--commit-head ()
  "Return HEAD's full object name, or signal a user error."
  (let ((root neo-git-root))
    (with-temp-buffer
      (unless (zerop (process-file (neo-git--executable) nil t nil
                                  "-C" root "rev-parse" "--verify" "HEAD"))
        (user-error "There is no commit to edit"))
      (string-trim (buffer-string)))))

(defun neo-git-commit-menu ()
  "Choose a commit operation for the status or selected history commit."
  (interactive)
  (let ((target (and (eq neo-git--browser-kind 'history) (tabulated-list-get-id)))
        (owner (neo-git--status-owner)))
    (with-current-buffer owner
      (pcase (read-char-choice
              "Commit: [c] new  [a] amend HEAD  [w] reword HEAD  [f] fixup  [q] cancel "
              '(?c ?a ?w ?f ?q))
        (?c (neo-git-commit))
        (?a (neo-git-commit 'amend))
        (?w (neo-git-commit 'reword))
        (?f (neo-git-commit-fixup target))))))

(defun neo-git-commit-fixup (&optional target)
  "Create a fixup commit targeting a commit reachable from HEAD."
  (interactive)
  (when (or neo-git--mutation (neo-git--in-progress-p))
    (user-error "Finish the current Git operation first"))
  (unless (seq-some (lambda (e) (eq (plist-get e :kind) 'staged)) neo-git-entries)
    (user-error "Stage changes before creating a fixup"))
  (let* ((head (neo-git--commit-head))
         (choices (process-lines (neo-git--executable) "-C" neo-git-root
                                 "log" "-100" "--format=%H %s"))
         (ref (or target (car (split-string
                              (completing-read "Fixup commit: " choices nil t)))))
         (oid (car (process-lines (neo-git--executable) "-C" neo-git-root
                                  "rev-parse" "--verify" (concat ref "^{commit}")))))
    (unless (zerop (process-file (neo-git--executable) nil nil nil "-C" neo-git-root
                                "merge-base" "--is-ancestor" oid head))
      (user-error "Fixup target must be an ancestor of HEAD"))
    (neo-git--mutate (list "commit" (concat "--fixup=" oid) "--no-edit")
                     (concat "fixup " (substring oid 0 8)))))

(defun neo-git-commit (&optional kind)
  "Edit a new commit message, or amend/reword HEAD according to KIND."
  (interactive)
  (unless (memq kind '(nil amend reword)) (user-error "Unknown commit operation"))
  (when neo-git--mutation
    (user-error "Git operation already running"))
  (when (and kind (neo-git--in-progress-p))
    (user-error "Finish the current Git operation before editing a commit"))
  (when (and (not kind) (not (seq-some (lambda (e)
                                       (eq (plist-get e :kind) 'staged)) neo-git-entries)))
    (user-error "Stage changes before committing"))
  (let* ((status-buffer (current-buffer))
         (head (and kind (neo-git--commit-head)))
         (staged (seq-filter (lambda (e) (eq (plist-get e :kind) 'staged)) neo-git-entries))
         (buffer (get-buffer-create (format "*Neo Git Commit %s: %s*" (or kind 'new)
                                            (directory-file-name neo-git-root)))))
    (when (and kind
               (not (yes-or-no-p (format "%s HEAD %s? This rewrites the commit. "
                                         (capitalize (symbol-name kind)) (substring head 0 8)))))
      (user-error "Commit editing cancelled"))
    (with-current-buffer buffer
      (unless (eq major-mode 'text-mode)
        (text-mode))
      (when (and kind (zerop (buffer-size)))
        (let ((coding-system-for-read 'utf-8-unix))
          (process-file (neo-git--executable) nil t nil "-C"
                        (buffer-local-value 'neo-git-root status-buffer)
                        "log" "-1" "--format=%B")))
      ;; Like git commit: a '#' summary of staged files, stripped on finish.
      (save-excursion
        (goto-char (point-min))
        (flush-lines "^#")
        (goto-char (point-max))
        (skip-chars-backward " \t\n")
        (delete-region (point) (point-max))
        (insert "\n\n# Lines starting with '#' are ignored.\n"
                (if (eq kind 'reword) "# Message only; staged changes remain staged.\n"
                  "# Changes to be committed:\n"))
        (dolist (entry (unless (eq kind 'reword) staged))
          (insert "#\t" (if (plist-get entry :old-path)
                            (format "%s -> " (plist-get entry :old-path))
                          "")
                  (plist-get entry :path) "\n")))
      (setq-local neo-git--commit-status-buffer status-buffer
                  neo-git--commit-kind kind
                  neo-git--commit-head head
                  neo-git--commit-root (buffer-local-value 'neo-git-root status-buffer))
      (use-local-map (copy-keymap text-mode-map))
      (local-set-key (kbd "C-c C-c") #'neo-git-commit-finish)
      (local-set-key (kbd "C-c C-k") #'neo-git-commit-cancel))
    (switch-to-buffer buffer)
    (when (fboundp 'evil-insert-state)
      (evil-insert-state))
    buffer))

(defvar-local neo-git--commit-status-buffer nil)
(defvar-local neo-git--commit-root nil)

(defun neo-git-commit-finish ()
  (interactive)
  (let ((message-text (string-trim (replace-regexp-in-string "^#.*\n?" "" (buffer-string))))
        (kind neo-git--commit-kind)
        (head neo-git--commit-head)
        (status-buffer neo-git--commit-status-buffer))
    (when (string-empty-p message-text)
      (user-error "Commit message is empty"))
    (unless (buffer-live-p status-buffer)
      (user-error "Git status screen is closed"))
    (when (buffer-local-value 'neo-git--mutation status-buffer)
      (user-error "Git operation already running"))
    (when kind
      (with-current-buffer status-buffer
        (when (neo-git--in-progress-p) (user-error "Finish the current Git operation first"))
        (unless (equal head (neo-git--commit-head))
          (user-error "HEAD changed since this draft was opened; reopen commit editing"))))
    (let ((file (make-temp-file "neo-git-message-"))
          (commit-buffer (current-buffer)))
      (let ((coding-system-for-write 'utf-8-unix))
        (write-region message-text nil file nil 'silent))
      (with-current-buffer status-buffer
        (when neo-git--mutation
          (user-error "Git operation already running"))
        (setq neo-git--mutation t)
        (setq neo-git--mutation-label "commit")
        (neo-git--progress-begin)
        (neo-git--render)
        (let ((process
               (neo-git--run
                neo-git-root (append '("commit")
                                     (when kind '("--amend"))
                                     (when (eq kind 'reword) '("--only"))
                                     (list "-F" file))
                (lambda (status _output error-output)
                  (when (file-exists-p file)
                    (delete-file file))
                  (when (buffer-live-p status-buffer)
                    (with-current-buffer status-buffer
                      (setq neo-git--mutation nil
                            neo-git--mutation-label nil)
                      (neo-git--progress-stop)
                      (if (and (integerp status) (zerop status))
                          (progn
                            (setq neo-git--last-error nil)
                            (when (buffer-live-p commit-buffer)
                              (kill-buffer commit-buffer))
                            (unless neo-git--closed
                              (when (fboundp 'diff-hl-update)
                                (diff-hl-update))
                              (neo-git-refresh)))
                        (setq neo-git--last-error
                              (if (string-empty-p (string-trim error-output))
                                  (format "Git exited with status %s" status)
                                (string-trim error-output)))
                        (unless neo-git--closed
                          (message "Neo Git commit failed: %s" neo-git--last-error)
                          (neo-git--render))))))
                )))
          (when (and neo-git--mutation (process-live-p process))
            (neo-git--progress-set-process process)))))))

(defun neo-git-commit-cancel ()
  (interactive)
  (kill-buffer (current-buffer)))

;;; Remote operations

(defun neo-git--remote-choice (prompt)
  (let ((remotes (process-lines (neo-git--executable) "-C" neo-git-root "remote")))
    (unless remotes
      (user-error "No Git remote is configured"))
    (completing-read prompt remotes nil t)))

(defun neo-git-fetch ()
  (interactive)
  (let ((remote (neo-git--remote-choice "Fetch remote: ")))
    (message "Fetching %s…" remote)
    (neo-git--mutate (list "fetch" "--progress" remote) (format "fetch %s" remote))))

(defun neo-git--read-config (key)
  (let ((root neo-git-root))
    (with-temp-buffer
      (when (zerop (process-file (neo-git--executable) nil t nil "-C" root "config" "--get" key))
        (string-trim (buffer-string))))))

(defun neo-git--current-branch ()
  (let ((branch (process-lines (neo-git--executable) "-C" neo-git-root "branch" "--show-current")))
    (and branch (not (string-empty-p (car branch))) (car branch))))

(defun neo-git--upstream-target ()
  (let* ((branch (neo-git--current-branch))
         (remote (and branch (neo-git--read-config (concat "branch." branch ".remote"))))
         (merge (and branch (neo-git--read-config (concat "branch." branch ".merge")))))
    (unless branch
      (user-error "Detached HEAD has no upstream"))
    (if (and remote merge)
        (list remote (string-remove-prefix "refs/heads/" merge))
      (let ((remotes (process-lines (neo-git--executable) "-C" neo-git-root "remote")))
        (unless remotes
          (user-error "No Git remote is configured"))
        (let ((selected-remote (completing-read "Set upstream remote: " remotes nil t))
              (selected-branch (read-string "Upstream branch: " branch)))
          (when (or (string-empty-p selected-branch)
                    (string-prefix-p "-" selected-branch)
                    (not (zerop (process-file (neo-git--executable) nil nil nil
                                              "-C" neo-git-root "check-ref-format"
                                              "--branch" selected-branch))))
            (user-error "Invalid Git branch name: %s" selected-branch))
          (list selected-remote selected-branch))))))

(defun neo-git--in-progress-p ()
  "Return the Git command of the merge, rebase, cherry-pick or revert in progress."
  (let ((paths (process-lines (neo-git--executable) "-C" neo-git-root
                              "rev-parse" "--git-path" "MERGE_HEAD"
                              "--git-path" "CHERRY_PICK_HEAD"
                              "--git-path" "REVERT_HEAD"
                              "--git-path" "rebase-merge"
                              "--git-path" "rebase-apply")))
    (cl-loop for path in paths
             for operation in '("merge" "cherry-pick" "revert" "rebase" "rebase")
             when (file-exists-p (expand-file-name path neo-git-root))
             return operation)))

(defun neo-git-pull ()
  (interactive)
  (when (seq-some (lambda (e)
                    (eq (plist-get e :kind) 'conflict)) neo-git-entries)
    (user-error "Resolve conflicts in your Git tool before pulling"))
  (when (neo-git--in-progress-p)
    (user-error "Finish the current merge/rebase before pulling"))
  (let ((target (neo-git--upstream-target)))
    (neo-git--mutate (append '("pull" "--progress") target)
                     (format "pull %s/%s" (car target) (cadr target)))))

(defun neo-git-push ()
  (interactive)
  (let ((target (neo-git--upstream-target)))
    (neo-git--mutate (append '("push" "--progress" "--set-upstream")
                             (list (car target) (concat "HEAD:refs/heads/" (cadr target))))
                     (format "push %s/%s" (car target) (cadr target)))))

;;; History, branches and stash

(defvar neo-git-sequence-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map text-mode-map)
    (define-key map (kbd "C-c C-c") #'neo-git-editor-finish)
    (define-key map (kbd "C-c C-k") #'neo-git-editor-cancel)
    (define-key map (kbd "C-c C-a") #'neo-git-sequence-action)
    map))

(define-derived-mode neo-git-sequence-mode text-mode "Neo-Git-Rebase"
  "Edit Git's rebase sequence. Reorder lines with normal editing commands.
C-c C-a chooses pick/reword/edit/squash/fixup/drop for the current line.
C-c C-c saves and continues; C-c C-k cancels this editor invocation."
  (setq-local header-line-format
              " Reorder lines; C-c C-a: action  C-c C-c: run  C-c C-k: cancel"))

(defun neo-git-sequence-action ()
  "Change the action of the current rebase todo line."
  (interactive)
  (beginning-of-line)
  (unless (looking-at "\\(?:pick\\|reword\\|edit\\|squash\\|fixup\\|drop\\|[presfd]\\) ")
    (user-error "Select a commit action; merge structure lines must remain intact"))
  (let ((end (match-end 0))
        (action (completing-read "Action: " '("pick" "reword" "edit" "squash" "fixup" "drop") nil t)))
    (delete-region (point) end)
    (insert action " ")))

(defun neo-git-editor-finish ()
  "Save the Git editor buffer and release its waiting emacsclient."
  (interactive)
  (require 'server)
  (unless server-buffer-clients (user-error "This buffer has no waiting Git editor"))
  (save-buffer)
  (server-edit))

(defun neo-git-editor-cancel ()
  "Cancel only the clients editing this Git buffer, leaving the draft intact."
  (interactive)
  (require 'server)
  (unless server-buffer-clients (user-error "This buffer has no waiting Git editor"))
  ;; `server-edit-abort' broadcasts to all clients. Restrict it to this file.
  (let ((server-clients server-buffer-clients)) (server-edit-abort)))

(defun neo-git--prepare-editor-buffer ()
  "Set up an editor buffer requested by a running Neo Git operation."
  (when buffer-file-name
    (let* ((file buffer-file-name)
           (owner (cl-find-if
                   (lambda (buffer)
                     (let ((directory (buffer-local-value 'neo-git--editor-directory buffer)))
                       (and directory (buffer-local-value 'neo-git--mutation buffer)
                            (file-in-directory-p file directory))))
                   (buffer-list))))
      (when owner
        (if (equal (file-name-nondirectory file) "git-rebase-todo")
            (neo-git-sequence-mode)
          (text-mode)
          (use-local-map (copy-keymap text-mode-map))
          (local-set-key (kbd "C-c C-c") #'neo-git-editor-finish)
          (local-set-key (kbd "C-c C-k") #'neo-git-editor-cancel)
          (setq-local header-line-format " Git message: C-c C-c: save/continue  C-c C-k: cancel"))
        (when (fboundp 'evil-insert-state) (evil-insert-state))))))

(defun neo-git--mutate-with-editor (arguments label worktree)
  "Run ARGUMENTS with Git's message and sequence editors in this Emacs."
  (when neo-git--mutation (user-error "Git operation already running"))
  (when worktree (neo-git--worktree-ready (eq worktree 'resume)))
  (require 'server)
  (let ((client (or (executable-find "emacsclient")
                    (let ((file (expand-file-name
                                 (if (eq system-type 'windows-nt) "emacsclient.exe" "emacsclient")
                                 invocation-directory)))
                      (and (file-executable-p file) file)))))
    (unless client (user-error "emacsclient is required for interactive Git editing"))
    (unless (process-live-p server-process)
      ;; Do not replace an existing server belonging to a different Emacs.
      (when (server-running-p server-name)
        (setq server-name (format "neo-git-%s" (emacs-pid))))
      (server-start))
    (add-hook 'server-switch-hook #'neo-git--prepare-editor-buffer)
    (let* ((endpoint (expand-file-name server-name
                                      (if server-use-tcp server-auth-dir server-socket-dir)))
           (editor (mapconcat #'shell-quote-argument
                              (list client (if server-use-tcp "--server-file" "--socket-name")
                                    endpoint) " "))
           (process-environment (copy-sequence process-environment))
           (neo-git--interactive-editor editor))
      (setenv "GIT_EDITOR" editor)
      (setenv "GIT_SEQUENCE_EDITOR" editor)
      (setq neo-git--editor-directory
            (file-name-as-directory
             (car (process-lines (neo-git--executable) "-C" neo-git-root
                                 "rev-parse" "--absolute-git-dir"))))
      (condition-case err
          (neo-git--mutate arguments label nil worktree)
        (error (setq neo-git--editor-directory nil)
               (signal (car err) (cdr err)))))))

(defun neo-git-rebase-interactive (&optional base autosquash)
  "Edit the rebase sequence after BASE, optionally with AUTOSQUASH."
  (interactive)
  (with-current-buffer (neo-git--status-owner)
    (neo-git--worktree-ready)
    (let* ((ref (or base (read-string "Rebase commits after (base): " "HEAD~1")))
           (oid (car (process-lines (neo-git--executable) "-C" neo-git-root
                                    "rev-parse" "--verify" (concat ref "^{commit}")))))
      (unless (zerop (process-file (neo-git--executable) nil nil nil "-C" neo-git-root
                                  "merge-base" "--is-ancestor" oid "HEAD"))
        (user-error "Choose an ancestor of HEAD as the rebase base"))
      (when (yes-or-no-p (format "Rewrite commits after %s%s? " (substring oid 0 8)
                                (if autosquash " with autosquash" "")))
        (neo-git--mutate-with-editor
         (append '("rebase" "--interactive" "--rebase-merges")
                 (when autosquash '("--autosquash")) (list oid))
         "interactive rebase" t)))))

(defun neo-git-rebase-menu ()
  "Choose a normal rebase, interactive rebase, or autosquash."
  (interactive)
  (pcase (read-char-choice "Rebase: [r] onto branch  [i] interactive  [a] autosquash  [q] cancel "
                          '(?r ?i ?a ?q))
    (?r (neo-git-rebase))
    (?i (neo-git-rebase-interactive))
    (?a (neo-git-rebase-interactive nil t))))

(defun neo-git--selected-commit ()
  "Return the history/reflog commit at point, or read and resolve a ref."
  (let ((ref (or (and (memq neo-git--browser-kind '(history reflog)) (tabulated-list-get-id))
                 (read-string "Commit: " "HEAD")))
        (root neo-git-root))
    (when (string-prefix-p "-" ref) (user-error "Invalid commit reference"))
    (car (process-lines (neo-git--executable) "-C" root
                       "rev-parse" "--verify" (concat ref "^{commit}")))))

(defun neo-git-recover-commit (&optional oid)
  "Create a recovery branch at OID without changing HEAD or the worktree."
  (interactive)
  (let ((target (or oid (neo-git--selected-commit)))
        (owner (or (neo-git--owner-buffer) (current-buffer))))
    (with-current-buffer owner
      (let ((name (neo-git--read-branch-name "Recovery branch name: ")))
        (neo-git--mutate (list "branch" name target) (concat "recover " name))))))

(defun neo-git-revert-commit (&optional oid)
  "Create a new commit undoing OID; merge commits require a separate Git command."
  (interactive)
  (let ((target (or oid (neo-git--selected-commit)))
        (owner (neo-git--status-owner)))
    (with-current-buffer owner
      (neo-git--worktree-ready)
      (when (yes-or-no-p (format "Revert %s with a new commit? " (substring target 0 8)))
        (neo-git--mutate (list "revert" "--no-edit" target) "revert commit" nil t)))))

(defun neo-git-reset-commit ()
  "Reset to a selected commit with an explicit soft/mixed/hard choice."
  (interactive)
  (let ((target (neo-git--selected-commit)) (owner (neo-git--status-owner)))
    (with-current-buffer owner
      (neo-git--worktree-ready)
      (let ((mode (completing-read "Reset mode: " '("soft" "mixed" "hard") nil t)))
        (when (yes-or-no-p (format "Reset %s to %s%s? " mode (substring target 0 8)
                                  (if (equal mode "hard") "; tracked local changes will be discarded" "")))
          (neo-git--mutate (list "reset" (concat "--" mode) target) "reset commit" nil t))))))

(defun neo-git-recovery-menu ()
  "Choose a reflog, recovery branch, revert or reset operation."
  (interactive)
  (pcase (read-char-choice "Recovery: [l] reflog  [b] recovery branch  [v] revert  [r] reset  [q] cancel "
                          '(?l ?b ?v ?r ?q))
    (?l (neo-git--browse 'reflog))
    (?b (neo-git-recover-commit))
    (?v (neo-git-revert-commit))
    (?r (neo-git-reset-commit))))

(defconst neo-git--branch-format
  '("--format=%(refname)%09%(refname:short)%09%(symref)%09%(HEAD)%09%(upstream:short)%09%(upstream:track)%09%(committerdate:short)%09%(subject)"
    "refs/heads/" "refs/remotes/")
  "`for-each-ref' arguments listing local, then remote branches.")

(defvar-local neo-git--history-all nil
  "Non-nil when the history pane shows all branches, remotes and tags.")
(defvar-local neo-git--browser-process nil)
(defvar-local neo-git--browser-generation 0)

(defvar neo-git-browser-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'neo-git-browser-show)
    (define-key map (kbd "r") #'neo-git-browser-refresh)
    (define-key map (kbd "j") #'next-line)
    (define-key map (kbd "k") #'previous-line)
    (define-key map (kbd "SPC") #'neo-git-browser-select)
    (define-key map (kbd "d") #'neo-git-browser-delete)
    (define-key map (kbd "D") #'neo-git-branch-force-delete)
    (define-key map (kbd "R") #'neo-git-branch-rename)
    (define-key map (kbd "B") #'neo-git-browser-create-branch)
    (define-key map (kbd "a") #'neo-git-history-toggle-all)
    (define-key map (kbd "C") #'neo-git-cherry-pick)
    (define-key map (kbd "q") #'neo-git-browser-quit)
    (define-key map (kbd "TAB") #'neo-git-browser-quit)
    (define-key map (kbd "<backtab>") #'neo-git-browser-quit)
    map))

(defface neo-git-ref-face '((t (:inherit font-lock-constant-face :weight bold)))
  "Face for branch and tag names in Neo Git history."
  :group 'neo-git)

(define-derived-mode neo-git-browser-mode tabulated-list-mode "Neo-Git-Browse"
  "Browse commits, branches or stash entries. RET: diff; r: refresh; q: return.
In history, a: toggle all branches; B: branch here; C: cherry-pick.
In branch lists, SPC: switch (remote: tracking branch); B: branch from it;
R: rename; d/D: delete/force delete.
In stash lists, SPC: apply without deleting; d: delete with confirmation."
  (setq-local truncate-lines t)
  (when (fboundp 'evil-define-key*)
    (evil-define-key* '(normal motion) neo-git-browser-mode-map
      (kbd "RET") #'neo-git-browser-show (kbd "r") #'neo-git-browser-refresh
      (kbd "j") #'next-line (kbd "k") #'previous-line
      (kbd "SPC") #'neo-git-browser-select (kbd "d") #'neo-git-browser-delete
      (kbd "D") #'neo-git-branch-force-delete (kbd "R") #'neo-git-branch-rename
      (kbd "B") #'neo-git-browser-create-branch (kbd "a") #'neo-git-history-toggle-all
      (kbd "C") #'neo-git-cherry-pick (kbd "TAB") #'neo-git-browser-quit (kbd "<backtab>") #'neo-git-browser-quit
      (kbd "q") #'neo-git-browser-quit (kbd "<escape>") #'neo-git-browser-quit)))

(defun neo-git-browser-quit ()
  "Return to the status list from the pinned history pane, else quit the window."
  (interactive)
  (let ((owner neo-git--diff-owner))
    (if (and (buffer-live-p owner)
             (eq (selected-window) (buffer-local-value 'neo-git--history-window owner)))
        (neo-git-focus-list)
      (quit-window))))

(defun neo-git--refresh-browsers (owner &optional kind)
  "Refresh OWNER's browser buffers, only those of KIND when non-nil."
  (dolist (browser (buffer-list))
    (when (buffer-live-p browser)
      (with-current-buffer browser
        (when (and (derived-mode-p 'neo-git-browser-mode)
                   (eq neo-git--diff-owner owner)
                   (or (null kind) (eq neo-git--browser-kind kind)))
          (neo-git-browser-refresh))))))

(defun neo-git--status-owner ()
  (let ((owner (or (neo-git--owner-buffer) (current-buffer))))
    (unless (and (buffer-live-p owner)
                 (with-current-buffer owner
                   (and (derived-mode-p 'neo-git-mode) neo-git-root
                        (not neo-git--closed))))
      (user-error "Open a Neo Git status buffer first"))
    owner))

(defun neo-git--worktree-ready (&optional resume)
  "Refuse worktree writes during a Git operation or unsaved file editing.
RESUME permits a merge/rebase in progress, for continuing or aborting it."
  (when neo-git--mutation (user-error "Git operation already running"))
  (when (and (not resume) (neo-git--in-progress-p))
    (user-error "Finish the current merge/rebase before changing the worktree"))
  (let ((root neo-git-root))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and buffer-file-name (buffer-modified-p)
                   (file-in-directory-p buffer-file-name root))
          (user-error "Save or discard edits first: %s" buffer-file-name))))))

(defun neo-git--revert-worktree-buffers ()
  (let ((root neo-git-root))
    ;; Reverting runs hooks and Git, which may kill buffers in this snapshot.
    (dolist (buffer (buffer-list))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (and buffer-file-name (not (buffer-modified-p))
                     (file-in-directory-p buffer-file-name root)
                     (file-exists-p buffer-file-name))
            (condition-case err
                (revert-buffer t t t)
              (error (message "Cannot reload %s: %s" buffer-file-name
                              (error-message-string err))))))))))

(defun neo-git--browser-buffer (kind owner)
  "Return OWNER's browser buffer of KIND, starting its refresh."
  (let* ((root (buffer-local-value 'neo-git-root owner))
         (buffer (get-buffer-create (format "*Neo Git %s: %s*" kind root))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'neo-git-browser-mode) (neo-git-browser-mode))
      (setq neo-git-root root default-directory root
            neo-git--diff-owner owner neo-git--browser-kind kind
            tabulated-list-format
            (pcase kind
              ;; Unsortable: sorting would scramble the graph.
              ('history (vector (list "Graph" 1 nil) (list "Commit" 8 nil)
                                (list "Date" 11 nil) (list "Subject" 0 nil)))
              ('branches [("" 1 nil) ("Branch" 32 nil) ("Upstream" 28 nil)
                          ("Date" 11 nil) ("Subject" 0 nil)])
              ('reflog [("Reflog" 20 nil) ("Operation" 0 nil)])
              (_ [("Stash" 16 t) ("Subject" 0 t)])))
      (tabulated-list-init-header)
      (neo-git-browser-refresh))
    buffer))

(defun neo-git--browse (kind)
  (let* ((owner (neo-git--status-owner))
         (buffer (neo-git--browser-buffer kind owner))
         (window (and (eq kind 'history)
                      (buffer-local-value 'neo-git--history-window owner))))
    (if (window-live-p window)
        (progn (set-window-buffer window buffer)
               (select-window window))
      (pop-to-buffer buffer))))

(defconst neo-git--graph-colors
  '("#6fbfae" "#e5c07b" "#a9c27a" "#e06c75" "#d78fbf" "#61afef")
  "Lane colors for the history graph, cycled as branch lanes appear.")

(defun neo-git--graph-string (cells)
  "Join CELLS of (CHAR . COLOR) or nil into a colored graph string."
  (string-trim-right
   (mapconcat (lambda (cell)
                (if cell (propertize (string (car cell)) 'face (list :foreground (cdr cell)))
                  " "))
              cells "")))

(defun neo-git--history-entries (output)
  "Parse `git log' OUTPUT of id, parents and columns into graph entries.
One row per commit: ● commit, ○ merge, <─┐ merged branch, ─┘ fork point."
  (let (lanes (next 0) rows)
    (cl-labels ((alloc (oid)
                  (let ((i (or (cl-position nil lanes)
                               (progn (setq lanes (nconc lanes (list nil)))
                                      (1- (length lanes))))))
                    (setf (nth i lanes)
                          (cons oid (nth (mod next (length neo-git--graph-colors))
                                         neo-git--graph-colors)))
                    (cl-incf next)
                    i))
                (lane (oid) (cl-position oid lanes :key #'car-safe :test #'equal)))
      (dolist (line (split-string output "
" t))
        (pcase-let* ((`(,oid ,parents ,hash ,date ,refs . ,subject) (split-string line ""))
                     (parents (split-string parents " " t))
                     (above (copy-sequence lanes))
                     (col (or (lane oid) (alloc oid)))
                     (color (cdr (nth col lanes)))
                     (closing nil) (links nil))
          ;; Other lanes waiting for this commit branched off here.
          (dotimes (k (length lanes))
            (when (and (/= k col) (equal (car-safe (nth k lanes)) oid))
              (push (cons k (cdr (nth k lanes))) closing)
              (setf (nth k lanes) nil)))
          (setf (nth col lanes) (and parents (cons (car parents) color)))
          (dolist (parent (cdr parents))
            (let* ((j (lane parent))
                   (corner (if j (if (> j col) ?┤ ?├) (setq j (alloc parent)) (if (> j col) ?┐ ?┌))))
              (push (list j (cdr (nth j lanes)) corner) links)))
          (let ((cells (make-vector (* 2 (length lanes)) nil)))
            (cl-flet ((line-to (j color corner arrow)
                        (let ((from (if (> j col) (1+ (* 2 col)) (1+ (* 2 j))))
                              (to (if (> j col) (1- (* 2 j)) (1- (* 2 col)))))
                          (cl-loop for i from from to to
                                   unless (aref cells i) do (aset cells i (cons ?─ color)))
                          (aset cells (* 2 j) (cons corner color))
                          (when arrow
                            (aset cells (if (> j col) (1+ (* 2 col)) (1- (* 2 col)))
                                  (cons (if (> j col) ?< ?>) color))))))
              (dotimes (k (length lanes))
                (when (and (/= k col) (nth k lanes) (nth k above))
                  (aset cells (* 2 k) (cons ?│ (cdr (nth k lanes))))))
              (dolist (link links) (line-to (nth 0 link) (nth 1 link) (nth 2 link) t))
              (dolist (close closing)
                ;; A merged branch may reuse the lane ending here: ┐+┘ → ┤.
                (line-to (car close) (cdr close)
                         (pcase (car (aref cells (* 2 (car close))))
                           (?┐ ?┤) (?┌ ?├) (_ (if (> (car close) col) ?┘ ?└)))
                         nil))
              (aset cells (* 2 col) (cons (if (cdr parents) ?○ ?●) color)))
            (push (list oid
                        (vector (neo-git--graph-string cells)
                                (propertize hash 'face 'font-lock-comment-face)
                                date
                                (concat (unless (string-empty-p refs)
                                          (propertize (format "(%s) " refs) 'face 'neo-git-ref-face))
                                        (string-join subject " "))))
                  rows))
          (while (and lanes (null (car (last lanes))))
            (setq lanes (butlast lanes))))))
    (setq rows (nreverse rows))
    (setf (cadr (aref tabulated-list-format 0))
          (apply #'max 1 (mapcar (lambda (row) (string-width (aref (cadr row) 0))) rows)))
    rows))

(defun neo-git-history ()
  "Show the latest 100 commits on the current branch with their graph."
  (interactive)
  (neo-git--browse 'history))

(defun neo-git-branch-list ()
  "Browse local and remote branches."
  (interactive)
  (neo-git--browse 'branches))

(defun neo-git-history-toggle-all ()
  "Toggle the history between HEAD only and all branches, remotes and tags."
  (interactive)
  (unless (eq neo-git--browser-kind 'history) (user-error "Open the history first"))
  (setq neo-git--history-all (not neo-git--history-all))
  (neo-git-browser-refresh))

(defun neo-git--branch-entries (output)
  "Parse `neo-git--branch-format' OUTPUT into tabulated entries, skipping symrefs."
  (cl-loop for line in (split-string output "\n" t)
           for (ref short symref head upstream track date . subject) = (split-string line "\t")
           when (string-empty-p symref)
           collect (list ref (vector (if (equal head "*") "*" "")
                                     (propertize short 'face (if (equal head "*")
                                                                 'neo-git-ref-face
                                                               'default))
                                     (string-trim (concat upstream " " track))
                                     date (string-join subject "\t")))))

(defun neo-git-stash-list ()
  "Browse saved stash entries."
  (interactive)
  (neo-git--browse 'stash))

(defun neo-git-browser-refresh ()
  (interactive)
  (let ((buffer (current-buffer))
        (generation (cl-incf neo-git--browser-generation)))
    (when (process-live-p neo-git--browser-process)
      (delete-process neo-git--browser-process))
    (setq header-line-format " Loading…")
    (setq neo-git--browser-process
          (neo-git--run
           neo-git-root
           (pcase neo-git--browser-kind
             ('history (append '("log" "--topo-order" "-100" "--date=short" "--color=never"
                                 "--format=%H%x1f%P%x1f%h%x1f%ad%x1f%D%x1f%s")
                               (when neo-git--history-all '("--branches" "--remotes" "--tags"))))
             ('branches (cons "for-each-ref" neo-git--branch-format))
             ('reflog '("reflog" "-100" "--format=%H%x09%gd%x09%gs"))
             (_ '("stash" "list" "--format=%H%x09%gd%x09%gs")))
           (lambda (status output errors)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (when (= generation neo-git--browser-generation)
                   (setq neo-git--browser-process nil)
                   (if (not (eq status 0))
                       (setq header-line-format
                             (neo-git--mode-line-literal (concat " " errors)))
                     (setq tabulated-list-entries
                           (pcase neo-git--browser-kind
                             ('history (neo-git--history-entries output))
                             ('branches (neo-git--branch-entries output))
                             (_
                           (mapcar
                            (lambda (line)
                              (let* ((fields (split-string line "\t"))
                                     (columns (if (eq neo-git--browser-kind 'history) 3 2)))
                                (list (car fields)
                                      (vconcat (seq-take (cdr fields) (1- columns))
                                               (list (mapconcat #'identity
                                                                (nthcdr columns fields) "\t"))))))
                            (split-string output "\n" t)))))
                     (setq header-line-format
                           (if tabulated-list-entries
                               (pcase neo-git--browser-kind
                                 ('stash " SPC: apply (keep stash)  RET: diff  d: delete  r: refresh  q: back")
                                 ('branches " SPC: switch  B: new from  R: rename  d/D: delete  RET: diff  q: back")
                                 ('reflog " Reflog: RET: diff  B: recovery branch  z: recovery menu  q: back")
                                 (_ (concat (if neo-git--history-all " All branches" " Current branch")
                                            ", latest 100  RET: diff  a: all/current  B: branch here"
                                            "  C: cherry-pick  q/TAB: list")))
                             " No entries  r: refresh  q: back"))
                     (tabulated-list-print t))))))))))

(defun neo-git-browser-show ()
  "Show the selected commit or stash without enabling index changes."
  (interactive)
  (let* ((oid (or (tabulated-list-get-id) (user-error "Select an entry")))
         (buffer (get-buffer-create (format "*Neo Git Show: %s*" oid)))
         (args (if (eq neo-git--browser-kind 'stash)
                   (list "stash" "show" "-p" "--include-untracked")
                 '("show" "--format=fuller"))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)) (erase-buffer) (insert "Loading…\n"))
      (diff-mode)
      (setq buffer-read-only t)
      (let ((map (make-sparse-keymap)))
        (set-keymap-parent map diff-mode-map)
        (define-key map (kbd "q") #'quit-window)
        (define-key map (kbd "<escape>") #'quit-window)
        (use-local-map map)
        (when (fboundp 'evil-define-key*)
          (evil-define-key* '(normal motion) map
            (kbd "q") #'quit-window (kbd "<escape>") #'quit-window))))
    (neo-git--run
     neo-git-root (append args '("--no-ext-diff" "--no-textconv" "--no-color") (list oid))
     (lambda (status output errors)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (let ((inhibit-read-only t))
             (erase-buffer) (insert (if (eq status 0) output errors))
             (goto-char (point-min)))))))
    (let ((window (and (buffer-live-p neo-git--diff-owner)
                       (buffer-local-value 'neo-git--preview-window neo-git--diff-owner))))
      (if (window-live-p window)
          (progn (select-window window)
                 (switch-to-buffer buffer nil t))
        (pop-to-buffer buffer)))))

(defun neo-git--branches ()
  "Return (SHORT-NAME . FULL-REFNAME) for local and remote branches."
  (mapcar (lambda (entry) (cons (substring-no-properties (aref (cadr entry) 1)) (car entry)))
          (neo-git--branch-entries
           (mapconcat #'identity (apply #'process-lines (neo-git--executable) "-C" neo-git-root
                                        "for-each-ref" neo-git--branch-format)
                      "\n"))))

(defun neo-git--switch-ref (ref)
  "Switch to full refname REF; a remote branch gets a local tracking branch."
  (if (string-prefix-p "refs/heads/" ref)
      (let ((branch (string-remove-prefix "refs/heads/" ref)))
        (neo-git--mutate (list "switch" branch) (concat "switch " branch) nil t))
    (let* ((remote-branch (string-remove-prefix "refs/remotes/" ref))
           (local (substring remote-branch (1+ (string-search "/" remote-branch)))))
      (if (zerop (process-file (neo-git--executable) nil nil nil "-C" neo-git-root
                               "show-ref" "--verify" "--quiet" (concat "refs/heads/" local)))
          (neo-git--mutate (list "switch" local) (concat "switch " local) nil t)
        (neo-git--mutate (list "switch" "--track" remote-branch)
                         (concat "switch " local " (tracking " remote-branch ")") nil t)))))

(defun neo-git-switch-branch ()
  "Switch to a local branch, or to a tracking branch of a remote one."
  (interactive)
  (with-current-buffer (neo-git--status-owner)
    (neo-git--worktree-ready)
    (let* ((branches (or (neo-git--branches) (user-error "No branch")))
           (branch (completing-read "Switch branch: " branches nil t)))
      (neo-git--switch-ref (cdr (assoc branch branches))))))

(defun neo-git--read-branch-name (prompt &optional initial)
  (let ((branch (read-string prompt initial)))
    (when (or (string-empty-p branch) (string-prefix-p "-" branch)
              (not (zerop (process-file (neo-git--executable) nil nil nil
                                        "check-ref-format" "--branch" branch))))
      (user-error "Invalid branch name: %s" branch))
    branch))

(defun neo-git-create-branch (&optional start)
  "Create a branch at START (default HEAD) and switch to it."
  (interactive)
  (with-current-buffer (neo-git--status-owner)
    (neo-git--worktree-ready)
    (let ((branch (neo-git--read-branch-name
                   (if start (format "New branch from %s: " start) "New branch: "))))
      (neo-git--mutate (append (list "switch" "-c" branch) (and start (list start)))
                       (concat "create " branch) nil t))))

(defun neo-git--branch-at-point (&optional local)
  "Return the full refname of the branch row; LOCAL requires a local branch."
  (unless (eq neo-git--browser-kind 'branches) (user-error "Open the branch list first"))
  (let ((ref (or (tabulated-list-get-id) (user-error "Select a branch"))))
    (when (and local (not (string-prefix-p "refs/heads/" ref)))
      (user-error "Only local branches can be renamed or deleted here"))
    ref))

(defun neo-git-browser-select ()
  "Switch to the branch row, or apply the stash row."
  (interactive)
  (if (eq neo-git--browser-kind 'branches)
      (let ((ref (neo-git--branch-at-point)))
        (with-current-buffer (neo-git--status-owner)
          (neo-git--worktree-ready)
          (neo-git--switch-ref ref)))
    (neo-git-stash-apply)))

(defun neo-git-browser-create-branch ()
  "Create a branch from a row; reflog recovery preserves the current branch."
  (interactive)
  (unless (memq neo-git--browser-kind '(history branches reflog))
    (user-error "Open the history or branch list first"))
  (let ((oid (or (tabulated-list-get-id) (user-error "Select a row"))))
    (if (eq neo-git--browser-kind 'reflog)
        (neo-git-recover-commit oid)
      (neo-git-create-branch oid))))

(defun neo-git--branch-delete (force)
  (let* ((ref (neo-git--branch-at-point t))
         (branch (string-remove-prefix "refs/heads/" ref)))
    (when (yes-or-no-p (if force
                           (format "Force delete %s, losing unmerged commits? " branch)
                         (format "Delete branch %s? " branch)))
      (with-current-buffer (neo-git--status-owner)
        (neo-git--mutate (list "branch" (if force "-D" "-d") branch)
                         (concat "delete " branch))))))

(defun neo-git-browser-delete ()
  "Delete the local branch row (merged only), or the stash row."
  (interactive)
  (if (eq neo-git--browser-kind 'branches)
      (neo-git--branch-delete nil)
    (neo-git-stash-drop)))

(defun neo-git-branch-force-delete ()
  "Delete the local branch row even when it is not merged."
  (interactive)
  (neo-git--branch-delete t))

(defun neo-git-branch-rename ()
  "Rename the local branch row."
  (interactive)
  (let* ((old (string-remove-prefix "refs/heads/" (neo-git--branch-at-point t)))
         (new (neo-git--read-branch-name (format "Rename %s to: " old) old)))
    (with-current-buffer (neo-git--status-owner)
      (neo-git--mutate (list "branch" "-m" old new) (concat "rename " old)))))

;;; Merge, rebase and cherry-pick

(defun neo-git--read-ref (prompt)
  "Read a local or remote branch other than the current one."
  (let* ((current (neo-git--current-branch))
         (refs (remove current (mapcar #'car (neo-git--branches)))))
    (unless refs (user-error "No other branch"))
    (completing-read prompt refs nil t)))

(defun neo-git-merge ()
  "Merge a branch into HEAD.
While a merge, rebase or cherry-pick is in progress, continue or abort it."
  (interactive)
  (with-current-buffer (neo-git--status-owner)
    (if (neo-git--in-progress-p)
        (neo-git-continue)
      (neo-git--worktree-ready)
      (let ((ref (neo-git--read-ref "Merge branch: ")))
        (neo-git--mutate (list "merge" "--no-edit" ref) (concat "merge " ref) nil t)))))

(defun neo-git-rebase ()
  "Rebase the current branch onto another branch."
  (interactive)
  (with-current-buffer (neo-git--status-owner)
    (neo-git--worktree-ready)
    (let ((ref (neo-git--read-ref "Rebase onto: ")))
      (neo-git--mutate (list "rebase" ref) (concat "rebase " ref) nil t))))

(defun neo-git-cherry-pick ()
  "Apply the selected history commit onto HEAD."
  (interactive)
  (unless (eq neo-git--browser-kind 'history) (user-error "Open the history first"))
  (let ((oid (or (tabulated-list-get-id) (user-error "Select a commit"))))
    (with-current-buffer (neo-git--status-owner)
      (neo-git--worktree-ready)
      (when (y-or-n-p (format "Cherry-pick %s onto HEAD? " (substring oid 0 8)))
        (neo-git--mutate (list "cherry-pick" oid)
                         (concat "cherry-pick " (substring oid 0 8)) nil t)))))

(defun neo-git-continue ()
  "Continue, skip or abort the merge, rebase or cherry-pick in progress.
Resolve conflicts and stage the files before continuing."
  (interactive)
  (with-current-buffer (neo-git--status-owner)
    (let* ((operation (or (neo-git--in-progress-p)
                          (user-error "No merge, rebase or cherry-pick in progress")))
           (skip (not (equal operation "merge")))
           (choice (read-char-choice
                    (format "%s: [c] continue  [a] abort%s  [q] cancel "
                            operation (if skip "  [s] skip" ""))
                    (if skip '(?c ?a ?s ?q) '(?c ?a ?q))))
           (action (pcase choice (?c "--continue") (?s "--skip") (?a "--abort"))))
      (when (and (equal action "--abort")
                 (not (yes-or-no-p (format "Abort the %s and restore the previous state? "
                                           operation))))
        (setq action nil))
      (when action
        (if (and (equal action "--continue") (equal operation "rebase"))
            (neo-git--mutate-with-editor (list operation action)
                                        (format "%s continue" operation) 'resume)
          (neo-git--mutate (list operation action)
                           (format "%s %s" operation (substring action 2)) nil 'resume))))))

(defun neo-git-stash-save ()
  "Save changes, optionally including untracked files."
  (interactive)
  (with-current-buffer (neo-git--status-owner)
    (neo-git--worktree-ready)
    (let* ((message (read-string "Stash message: "))
           (untracked (y-or-n-p "Include untracked files? ")))
      (neo-git--mutate (append '("stash" "push") (when untracked '("--include-untracked"))
                               (list "-m" message)) "stash save" nil t))))

(defun neo-git-stash-apply ()
  "Restore the selected stash, preserving it and its staged state."
  (interactive)
  (unless (eq neo-git--browser-kind 'stash) (user-error "Open the stash list first"))
  (let ((oid (or (tabulated-list-get-id) (user-error "Select a stash"))))
    (with-current-buffer (neo-git--status-owner)
      (neo-git--mutate (list "stash" "apply" "--index" oid) "stash apply (keep)" nil t))))

(defun neo-git-stash-drop ()
  "Delete the selected stash after confirmation and checking its current identity."
  (interactive)
  (unless (eq neo-git--browser-kind 'stash) (user-error "Open the stash list first"))
  (let* ((oid (or (tabulated-list-get-id) (user-error "Select a stash")))
         (ref (aref (tabulated-list-get-entry) 0))
         (owner (neo-git--status-owner)))
    (when (yes-or-no-p (format "Permanently delete %s (%s)? " ref (substring oid 0 12)))
      (neo-git--run
       neo-git-root (list "rev-parse" "--verify" ref)
       (lambda (status output _errors)
         (when (buffer-live-p owner)
           (with-current-buffer owner
             (unless neo-git--closed
               (if (and (eq status 0) (equal oid (string-trim output)))
                   (neo-git--mutate (list "stash" "drop" ref) (concat "drop " ref))
                 (message "Stash list changed; refresh before deleting"))))))))))

(defun neo-git-stash ()
  "Choose a stash operation."
  (interactive)
  (pcase (read-char-choice "Stash: [s] save  [l] list/apply/delete  [q] cancel " '(?s ?l ?q))
    (?s (neo-git-stash-save))
    (?l (neo-git-stash-list))))

(dolist (map (list neo-git-mode-map neo-git-diff-mode-map))
  (dolist (binding '(("l" . neo-git-history) ("b" . neo-git-switch-branch)
                     ("B" . neo-git-create-branch) ("s" . neo-git-stash-save)
                     ("S" . neo-git-stash) ("3" . neo-git-branch-list)
                     ("4" . neo-git-history) ("5" . neo-git-stash-list)
                     ("m" . neo-git-merge) ("M" . neo-git-rebase-menu) ("A" . neo-git-continue)
                     ("C" . neo-git-commit-menu) ("z" . neo-git-recovery-menu)
                     ("E" . neo-git-resolve-conflict)))
    (define-key map (kbd (car binding)) (cdr binding))))
(with-eval-after-load 'evil
  (dolist (map (list neo-git-mode-map neo-git-diff-mode-map))
    (evil-define-key* '(normal motion) map
      (kbd "l") #'neo-git-history (kbd "b") #'neo-git-switch-branch
      (kbd "B") #'neo-git-create-branch (kbd "s") #'neo-git-stash-save
      (kbd "S") #'neo-git-stash (kbd "3") #'neo-git-branch-list
      (kbd "4") #'neo-git-history (kbd "5") #'neo-git-stash-list
      (kbd "m") #'neo-git-merge (kbd "M") #'neo-git-rebase-menu (kbd "A") #'neo-git-continue
      (kbd "C") #'neo-git-commit-menu (kbd "z") #'neo-git-recovery-menu
      (kbd "E") #'neo-git-resolve-conflict)))

(dolist (binding '(("c" . neo-git-commit-menu) ("M" . neo-git-rebase-menu)
                   ("z" . neo-git-recovery-menu)))
  (define-key neo-git-browser-mode-map (kbd (car binding)) (cdr binding)))
(with-eval-after-load 'evil
  (evil-define-key* '(normal motion) neo-git-browser-mode-map
    (kbd "c") #'neo-git-commit-menu (kbd "M") #'neo-git-rebase-menu
    (kbd "z") #'neo-git-recovery-menu))

(provide 'neo-git)
;;; neo-git.el ends here
