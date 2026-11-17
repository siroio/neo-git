;;; neo-vcs-svn.el --- Subversion backend for Neo VCS -*- lexical-binding: t; coding: utf-8; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Subversion XML queries and native working-copy actions.
;;; Code:
(require 'neo-vcs)
(require 'xml)

(defun neo-vcs-svn--xml (text tag)
  (let ((nodes (with-temp-buffer
                 (insert text)
                 (xml-parse-region (point-min) (point-max)))))
    (unless (and (= (length nodes) 1) (eq (xml-node-name (car nodes)) tag))
      (error "Expected a Subversion %s XML document" tag))
    (car nodes)))

(defun neo-vcs-svn--text (node tag)
  (mapconcat #'identity
             (cl-remove-if-not #'stringp (xml-node-children (car (xml-get-children node tag))))
             ""))

(defun neo-vcs-svn--root (context outputs)
  (let* ((document (neo-vcs-svn--xml (car outputs) 'info))
         (entry (car (xml-get-children document 'entry)))
         (wc-info (car (xml-get-children entry 'wc-info)))
         (path (neo-vcs-svn--text wc-info 'wcroot-abspath))
         (directory (plist-get context :root)))
    (unless (and (file-name-absolute-p path) (file-directory-p path)
                 (or (file-equal-p directory path) (file-in-directory-p directory path)))
      (error "Invalid Subversion working-copy root: %S" path))
    (plist-put (copy-sequence context) :root (file-name-as-directory (file-truename path)))))

(defun neo-vcs-svn--status-entry (context entry group)
  (let* ((wc (car (xml-get-children entry 'wc-status)))
         (item (xml-get-attribute wc 'item))
         (props (xml-get-attribute wc 'props))
         (status (cond
                  ((member item '("external" "ignored" "none")) nil)
                  ((or (equal (xml-get-attribute wc 'tree-conflicted) "true")
                       (equal props "conflicted")) 'conflict)
                  (t (pcase item
                       ((or "conflicted" "obstructed") 'conflict)
                       ((or "modified" "replaced" "merged") 'modified)
                       ("normal" (and (equal props "modified") 'modified))
                       ("added" 'added) ("deleted" 'deleted)
                       ((or "missing" "incomplete") 'missing)
                       ("unversioned" 'untracked)
                       (_ (error "Unknown Subversion file status: %S" item)))))))
    (when status
      (let* ((raw-path (xml-get-attribute entry 'path))
             (root-entry (equal raw-path "."))
             (path (if root-entry "." (neo-vcs--path context raw-path)))
             (moved-from (xml-get-attribute-or-nil wc 'moved-from))
             (moved-to (xml-get-attribute-or-nil wc 'moved-to)))
        (append (list :path path :status status :svn-item item)
                (when root-entry '(:root-entry t))
                (when group (list :group group))
                (when moved-from (list :old-path (neo-vcs--path context moved-from)))
                (when moved-to (list :svn-moved-to (neo-vcs--path context moved-to))))))))

(defun neo-vcs-svn--status (context outputs)
  (let ((document (neo-vcs-svn--xml (car outputs) 'status))
        entries)
    (dolist (container (xml-node-children document))
      (when (and (consp container) (memq (xml-node-name container) '(target changelist)))
        (let ((group (and (eq (xml-node-name container) 'changelist)
                          (xml-get-attribute-or-nil container 'name))))
          (dolist (entry (xml-get-children container 'entry))
            (when-let* ((item (neo-vcs-svn--status-entry context entry group)))
              (push item entries))))))
    (list :label "Subversion" :entries (nreverse entries))))

(defun neo-vcs-svn--revision-p (revision)
  (and (stringp revision) (string-match-p "\\`[0-9]+\\'" revision)))

(defun neo-vcs-svn--history (outputs)
  (let ((document (neo-vcs-svn--xml (car outputs) 'log)))
    (mapcar (lambda (entry)
              (let ((revision (xml-get-attribute entry 'revision)))
                (unless (neo-vcs-svn--revision-p revision)
                  (error "Invalid Subversion revision: %S" revision))
                (list :id revision :short (concat "r" revision)
                      :author (neo-vcs-svn--text entry 'author) :date (neo-vcs-svn--text entry 'date)
                      :subject (car (split-string (neo-vcs-svn--text entry 'msg) "\n")))))
            (xml-get-children document 'logentry))))

(defun neo-vcs-svn--command (context &rest args)
  (let ((config (plist-get context :svn-config-dir)))
    (list :args (append '("--non-interactive")
                        (when config (list (concat "--config-dir=" config)))
                        args))))

(defun neo-vcs-svn--diff (outputs)
  (neo-vcs--decode-diff-paths (car outputs) "Index: " "Property changes on: "))

(defun neo-vcs-svn--paths (context entries)
  (mapcar (lambda (path)
            ;; The last at-sign terminates a working-copy target's empty peg.
            (concat "./" path (when (string-search "@" path) "@")))
          (neo-vcs--paths context entries)))

(defun neo-vcs-svn--input (options key)
  (let ((value (plist-get options key)))
    (unless (and (stringp value) (not (string-empty-p (string-trim value)))
                 (not (string-search "\0" value)))
      (user-error "Subversion requires a %s" (substring (symbol-name key) 1)))
    value))

(defun neo-vcs-svn--check-targets (context operation count output)
  (let ((entries (xml-get-children (neo-vcs-svn--xml output 'info) 'entry)))
    (unless (= (length entries) count)
      (user-error "Subversion did not identify every selected path"))
    (dolist (entry entries)
      (let* ((wc-info (car (xml-get-children entry 'wc-info)))
             (root (neo-vcs-svn--text wc-info 'wcroot-abspath))
             (kind (xml-get-attribute entry 'kind))
             (schedule (neo-vcs-svn--text wc-info 'schedule)))
        (unless (and (file-name-absolute-p root) (file-equal-p root (plist-get context :root)))
          (user-error "Selected path belongs to a different Subversion working copy"))
        (unless (or (equal kind "file")
                    (and (eq operation 'commit) (equal kind "dir")
                         (member schedule '("normal" "add"))
                         (string-empty-p (neo-vcs-svn--text wc-info 'copy-from-url))))
          (user-error "Subversion would change an entire directory tree: %s"
                      (xml-get-attribute entry 'path)))))))

(defun neo-vcs-svn-request (context operation &optional target options)
  "Build a Subversion request for OPERATION in CONTEXT with TARGET and OPTIONS."
  (when (and target (memq operation '(update switch)))
    (user-error "This Subversion command operates on the working copy"))
  (let ((command (lambda (&rest args) (apply #'neo-vcs-svn--command context args))))
    (pcase operation
      ('root (list :commands (list (funcall command "info" "--xml" "--" "."))
                   :parse (lambda (outputs) (neo-vcs-svn--root context outputs))))
      ('status
       (list :commands (list (funcall command "status" "--xml" "--ignore-externals" "--" "."))
             :parse (lambda (outputs) (neo-vcs-svn--status context outputs))))
      ('history
       (list :commands (list (funcall command "log" "--xml" "--limit=100" "--revision" "HEAD:0" "--" "."))
             :parse #'neo-vcs-svn--history))
      ('diff
       (let ((path (if (and (plist-get target :root-entry) (equal (plist-get target :path) "."))
                       "."
                     (concat "./" (neo-vcs--path context (plist-get target :path))))))
         (unless (eq (plist-get target :status) 'untracked)
           ;; A local diff with no revision treats its target as a raw path.
           (list :commands (list (funcall command "diff" "--internal-diff" "--depth" "empty" "--" path))
                 :parse #'neo-vcs-svn--diff))))
      ('show
       (let ((revision (plist-get target :id)))
         (unless (neo-vcs-svn--revision-p revision) (user-error "Invalid Subversion revision"))
         (list :commands (list (funcall command "diff" "--internal-diff" "--change" revision "--" "."))
               :parse #'neo-vcs-svn--diff)))
      ((or 'add 'delete 'delete-file 'revert 'commit 'resolve)
       (let* ((paths (neo-vcs-svn--paths context target))
              (args (pcase operation
                      ('add '("add" "--depth" "empty"))
                      ((or 'delete 'delete-file) '("delete"))
                      ('revert '("revert" "--depth" "empty"))
                      ('commit (list "commit" "--depth" "empty"
                                     (concat "--message=" (neo-vcs-svn--input options :message))))
                      ('resolve '("resolve" "--depth" "empty" "--accept" "working")))))
         (list :commands
               (append
                (when (memq operation '(delete delete-file commit))
                  ;; Subversion deletes a versioned directory tree even at commit depth empty.
                  (list (append (apply command "info" "--xml" "--depth" "empty" "--" paths)
                                (list :check (lambda (output)
                                               (neo-vcs-svn--check-targets context operation
                                                                           (length paths) output))))))
                (list (apply command (append args '("--") paths))))
               :parse (lambda (outputs) (car (last outputs))))))
      ('update
       (list :commands (list (funcall command "update" "--ignore-externals" "--accept" "postpone" "--" "."))))
      ('switch
       (let ((url (neo-vcs-svn--input options :url)))
         (unless (or (string-prefix-p "^/" url)
                     (string-match-p "\\`[[:alpha:]][[:alnum:]+.-]*://" url))
           (user-error "Enter a Subversion branch URL or a ^/ repository-relative URL"))
         (list :commands (list (funcall command "switch" "--ignore-externals" "--accept" "postpone" "--" url ".")))))
      (_ (user-error "Unsupported Subversion operation: %s" operation)))))

(neo-vcs-register-backend
 'svn :program "svn" :request #'neo-vcs-svn-request
 :actions '((:id add :key "A" :label "Add selected files" :target files)
            (:id delete :key "d" :label "Delete selected paths" :target files
                 :destructive t :worktree t)
            (:id delete-file :key "D" :label "Delete file by name" :target file
                 :destructive t :worktree t)
            (:id revert :key "v" :label "Revert selected paths" :target files
                 :destructive t :worktree t)
            (:id commit :key "c" :label "Commit selected paths" :target files :input message :confirm t)
            (:id update :key "u" :label "Update working copy" :confirm t :worktree t)
            (:id switch :key "s" :label "Switch working copy to URL" :input url :confirm t :worktree t)
            (:id resolve :key "z" :label "Mark selected conflicts resolved with working files"
                 :target files :confirm t :worktree t)))

(provide 'neo-vcs-svn)
;;; neo-vcs-svn.el ends here
