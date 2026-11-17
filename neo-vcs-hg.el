;;; neo-vcs-hg.el --- Mercurial backend for Neo VCS -*- lexical-binding: t; coding: utf-8; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Mercurial CLI queries and native working-copy actions.
;;; Code:
(require 'neo-vcs)

(defun neo-vcs-hg--file-coding ()
  (or (and (eq system-type 'windows-nt) (bound-and-true-p w32-system-coding-system))
      file-name-coding-system default-file-name-coding-system locale-coding-system))

(defun neo-vcs-hg--line (output)
  (let ((line (string-remove-suffix "\n" output)))
    (if (eq system-type 'windows-nt)
        (decode-coding-string (encode-coding-string (string-remove-suffix "\r" line) 'utf-8-unix)
                              (neo-vcs-hg--file-coding))
      line)))

(defun neo-vcs-hg--root (context outputs)
  (let ((path (neo-vcs-hg--line (car outputs)))
        (directory (plist-get context :root)))
    (unless (and (file-name-absolute-p path) (file-directory-p path)
                 (or (file-equal-p directory path) (file-in-directory-p directory path)))
      (error "Invalid Mercurial root: %S" path))
    (plist-put (copy-sequence context) :root (file-name-as-directory (file-truename path)))))

(defun neo-vcs-hg--rows (text)
  (unless (string-prefix-p "[" (string-trim-left text))
    (error "Expected a Mercurial JSON array"))
  (neo-vcs--json text))

(defun neo-vcs-hg--file-name (hex)
  (unless (and (stringp hex) (zerop (% (length hex) 2))
               (string-match-p "\\`[[:xdigit:]]*\\'" hex))
    (error "Invalid Mercurial filename encoding"))
  (let* ((size (/ (length hex) 2))
         (bytes (make-string size 0))
         (coding (neo-vcs-hg--file-coding)))
    (dotimes (index size)
      (aset bytes index (string-to-number (substring hex (* 2 index) (* 2 (1+ index))) 16)))
    (let ((path (decode-coding-string bytes coding)))
      (unless (equal bytes (encode-coding-string path coding))
        (error "Mercurial filename cannot be represented by %s" coding))
      path)))

(defun neo-vcs-hg--status (context outputs)
  (let ((by-path (make-hash-table :test #'equal))
        (branch (neo-vcs-hg--line (nth 2 outputs)))
        entries)
    (dolist (line (split-string (car outputs) "\n" t))
      (let* ((row (neo-vcs--json line))
             (path (neo-vcs--path context (neo-vcs-hg--file-name (alist-get 'path_hex row))))
             (source (neo-vcs-hg--file-name (alist-get 'source_hex row)))
             (status (pcase (alist-get 'status row)
                       ("M" 'modified) ("A" 'added) ("R" 'deleted) ("!" 'missing)
                       ("?" 'untracked) ("C" 'clean) ("I" nil)
                       (code (error "Unknown Mercurial file status: %S" code)))))
        (when status
          (let ((entry (list :path path :status status)))
            (unless (string-empty-p source)
              (setq entry (plist-put entry :old-path (neo-vcs--path context source))))
            (puthash path entry by-path)
            (push entry entries)))))
    (dolist (line (split-string (nth 1 outputs) "\n" t))
      (let* ((row (neo-vcs--json line))
             (path (neo-vcs--path context (neo-vcs-hg--file-name (alist-get 'path_hex row)))))
        (pcase (alist-get 'mergestatus row)
          ("U"
           (if-let* ((entry (gethash path by-path)))
               (setf (plist-get entry :status) 'conflict)
             (push (list :path path :status 'conflict) entries)))
          ("R" nil)
          (code (error "Unknown Mercurial merge status: %S" code)))))
    (list :label (format "Mercurial · %s" branch) :entries (nreverse entries))))

(defun neo-vcs-hg--node-p (node)
  (and (stringp node) (string-match-p "\\`[[:xdigit:]]\\{40\\}\\'" node)))

(defun neo-vcs-hg--history (outputs)
  (mapcar
   (lambda (row)
     (let ((node (alist-get 'node row))
           (time (car (alist-get 'date row)))
           (author (alist-get 'user row))
           (message (alist-get 'desc row)))
       (unless (and (neo-vcs-hg--node-p node) (numberp time)
                    (stringp author) (stringp message))
         (error "Invalid Mercurial history entry: %S" row))
       (list :id node :short (substring node 0 12) :author author
             :date (format-time-string "%Y-%m-%dT%H:%M:%SZ" (seconds-to-time time) t)
             :subject (car (split-string message "\n")))))
   (neo-vcs-hg--rows (car outputs))))

(defun neo-vcs-hg--command (&rest args)
  (list :args (cons "--noninteractive" args)))

(defun neo-vcs-hg--diff (outputs)
  (neo-vcs--decode-diff-paths (car outputs) "diff --git "
                             "copy from " "copy to " "rename from " "rename to "))

(defun neo-vcs-hg--paths (context entries)
  (mapcar (lambda (path) (concat "filepath:" path)) (neo-vcs--paths context entries)))

(defun neo-vcs-hg--input (options key)
  (let ((value (plist-get options key)))
    (unless (and (stringp value) (not (string-empty-p (string-trim value)))
                 (not (string-search "\0" value)))
      (user-error "Mercurial requires a %s" (substring (symbol-name key) 1)))
    value))

(defun neo-vcs-hg--check-merge (output)
  (unless (neo-vcs-hg--history (list output))
    (user-error "There is no merge in progress. Use Commit selected files")))

(defun neo-vcs-hg-request (context operation &optional target options)
  "Build a Mercurial request for OPERATION in CONTEXT with TARGET and OPTIONS."
  (when (and target (memq operation '(commit-merge update bookmark merge pull push)))
    (user-error "This Mercurial command operates on the repository"))
  (pcase operation
    ('root (list :commands (list (neo-vcs-hg--command "root"))
                 :parse (lambda (outputs) (neo-vcs-hg--root context outputs))))
    ('status
     ;; Mercurial's built-in JSON style emits UTF-8 surrogates for legacy filename bytes.
     (list :commands (list (neo-vcs-hg--command "status" "--copies" "--template"
                                                "{dict(path_hex=path|hex,source_hex=source|hex,status=status)|json}\\n")
                           (neo-vcs-hg--command "resolve" "--list" "--template"
                                                "{dict(path_hex=path|hex,mergestatus=mergestatus)|json}\\n")
                           (neo-vcs-hg--command "branch"))
           :parse (lambda (outputs) (neo-vcs-hg--status context outputs))))
    ('history
     (list :commands (list (neo-vcs-hg--command "log" "--limit=100" "--template=json"))
           :parse #'neo-vcs-hg--history))
    ('diff
     (let ((paths (neo-vcs-hg--paths context (list target))))
       (unless (eq (plist-get target :status) 'untracked)
         (list :commands (list (apply #'neo-vcs-hg--command "diff" "--git" "--" paths))
               :parse #'neo-vcs-hg--diff))))
    ('show
     (let ((node (plist-get target :id)))
       (unless (neo-vcs-hg--node-p node) (user-error "Invalid Mercurial changeset"))
       (list :commands (list (neo-vcs-hg--command "diff" "--git" (concat "--change=" node)))
             :parse #'neo-vcs-hg--diff)))
    ((or 'add 'remove 'remove-file 'revert 'commit)
     (let* ((paths (neo-vcs-hg--paths context target))
            (args (pcase operation
                    ('add '("add"))
                    ((or 'remove 'remove-file) '("remove"))
                    ('revert '("revert"))
                    ('commit (list "commit" "--verbose"
                                   (concat "--message=" (neo-vcs-hg--input options :message)))))))
       (list :commands (list (apply #'neo-vcs-hg--command (append args '("--") paths))))))
    ('commit-merge
     (list :commands (list (append (neo-vcs-hg--command "log" "--rev=p2()" "--template=json")
                                   (list :check #'neo-vcs-hg--check-merge))
                           (neo-vcs-hg--command "commit" "--verbose"
                                                (concat "--message=" (neo-vcs-hg--input options :message))))
           :parse #'cadr))
    ('update
     (list :commands (list (neo-vcs-hg--command "update"
                                                (concat "--rev=" (neo-vcs-hg--input options :revision))))))
    ('bookmark
     (list :commands (list (neo-vcs-hg--command "bookmark" "--" (neo-vcs-hg--input options :name)))))
    ('merge
     (list :commands (list (neo-vcs-hg--command "merge" "--tool=internal:merge"
                                                (concat "--rev=" (neo-vcs-hg--input options :revision))))))
    ('pull (list :commands (list (neo-vcs-hg--command "pull"))))
    ('push (list :commands (list (neo-vcs-hg--command "push"))))
    (_ (user-error "Unsupported Mercurial operation: %s" operation))))

(neo-vcs-register-backend
 'hg :program "hg" :request #'neo-vcs-hg-request
 :environment '("HGPLAIN=1" "HGPLAINEXCEPT=")
 :actions '((:id add :key "A" :label "Add selected files" :target files)
            (:id remove :key "d" :label "Remove selected files" :target files
                 :destructive t :worktree t)
            (:id remove-file :key "D" :label "Remove file by name" :target file
                 :destructive t :worktree t)
            (:id revert :key "v" :label "Revert selected files" :target files
                 :destructive t :worktree t)
            (:id commit :key "c" :label "Commit selected files" :target files :input message)
            (:id commit-merge :key "C" :label "Commit merge (all changes)" :input message :confirm t)
            (:id update :key "u" :label "Update to revision" :input revision :worktree t :confirm t)
            (:id bookmark :key "b" :label "Create bookmark" :input name)
            (:id merge :key "M" :label "Merge revision" :input revision :worktree t :confirm t)
            (:id pull :key "f" :label "Pull from default repository" :confirm t)
            (:id push :key "P" :label "Push to default repository" :confirm t)))

(provide 'neo-vcs-hg)
;;; neo-vcs-hg.el ends here
