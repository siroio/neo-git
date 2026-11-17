;;; neo-vcs-jj.el --- Jujutsu backend -*- lexical-binding: t; coding: utf-8; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'neo-vcs)

(defconst neo-vcs-jj--status-template
  "json({\"path\" => path, \"status\" => status, \"source\" => source.path(), \"conflict\" => target.conflict()}) ++ \"\\n\"")
(defconst neo-vcs-jj--history-template
  "json({\"id\" => commit_id, \"change\" => change_id, \"author\" => author.name(), \"date\" => committer.timestamp().format(\"%Y-%m-%d %H:%M\"), \"subject\" => description.first_line()}) ++ \"\\n\"")

(defun neo-vcs-jj--records (text)
  (mapcar #'neo-vcs--json (split-string text "\n" t)))

(defun neo-vcs-jj--status (outputs)
  (let* ((current (neo-vcs--json (cadr outputs)))
         (revision (alist-get 'revision current)))
    (unless (and (stringp revision) (not (string-empty-p revision)))
      (error "Malformed jj working change"))
  (list :label (concat (substring revision 0 (min 12 (length revision))) " "
                      (or (alist-get 'description current) ""))
        :revision revision
        :entries
        (mapcar
         (lambda (row)
           (let ((path (alist-get 'path row)) (status (alist-get 'status row)))
             (unless (and (stringp path) (member status '("modified" "added" "removed" "copied" "renamed")))
               (error "Malformed jj diff entry"))
             (append
              (list :path path :status
                    (if (alist-get 'conflict row) 'conflict
                      (pcase status ("removed" 'deleted) ((or "added" "copied") 'added) (_ 'modified)))
                    :group "Working change")
              (when (equal status "renamed") (list :old-path (alist-get 'source row))))))
         (neo-vcs-jj--records (car outputs))))))

(defun neo-vcs-jj--history (outputs)
  (mapcar (lambda (row)
            (let ((id (alist-get 'id row)))
              (unless (and (stringp id) (string-match-p "\\`[0-9a-f]+\\'" id))
                (error "Malformed jj history revision"))
              (list :id id :short (substring id 0 (min 12 (length id)))
                    :change (alist-get 'change row) :author (alist-get 'author row)
                    :date (alist-get 'date row) :subject (alist-get 'subject row))))
          (neo-vcs-jj--records (car outputs))))

(defun neo-vcs-jj--filesets (context entries)
  "Return exact, quoted filesets, including both sides of a rename."
  (let ((paths (neo-vcs--paths context entries)))
    (dolist (entry entries)
      (when (plist-get entry :old-path)
        (push (neo-vcs--path context (plist-get entry :old-path)) paths)))
    (mapcar (lambda (path) (concat "root-file:" (json-encode-string path))) (delete-dups paths))))

(defun neo-vcs-jj-request (context operation &optional target options)
  "Describe a native Jujutsu OPERATION for CONTEXT."
  (let* ((prefix (list "--color=never" "--no-pager" "--repository" (plist-get context :root)))
         (command (lambda (args) (list :args (append prefix args)))))
    (pcase operation
      ('root
       (list :commands (list (funcall command '("root")))
             :parse (lambda (outputs)
                      (let ((root (file-name-as-directory (string-trim-right (car outputs) "[\r\n]+"))))
                        (unless (file-directory-p (expand-file-name ".jj" root))
                          (error "jj returned an invalid workspace root"))
                        (list :backend 'jj :root root)))))
      ('status
       (list :commands
             (list (funcall command (list "diff" "--template" neo-vcs-jj--status-template))
                   (funcall command '("log" "--no-graph" "-r" "@" "-T"
                                       "json({\"revision\" => change_id, \"description\" => description.first_line()})")))
             :parse #'neo-vcs-jj--status))
      ('history
       (list :commands (list (funcall command (list "log" "--no-graph" "--limit" "100"
                                                    "--revisions" "all()" "--template" neo-vcs-jj--history-template)))
             :parse #'neo-vcs-jj--history))
      ('diff
       (list :commands (list (funcall command (append '("diff" "--git" "--")
                                                       (neo-vcs-jj--filesets context (list target)))))))
      ('show
       (let ((id (plist-get target :id)))
         (unless (and (stringp id) (string-match-p "\\`[0-9a-f]+\\'" id))
           (user-error "Select a valid jj revision"))
         (list :commands (list (funcall command (list "diff" "--git" "--revisions" id))))))
      ((or 'describe 'split 'squash)
       (let ((message (plist-get options :message)))
         (unless (and (stringp message) (not (string-empty-p (string-trim message))))
           (user-error "Enter a change description"))
         (list :commands
               (list (funcall command
                              (append (list (symbol-name operation) "--message" message)
                                      (when (plist-get options :revision)
                                        (list "--revision" (plist-get options :revision)))
                                      (unless (eq operation 'describe)
                                        (cons "--" (neo-vcs-jj--filesets context target)))))))))
      ('restore
       (list :commands (list (funcall command (append '("restore" "--")
                                                       (neo-vcs-jj--filesets context target))))))
      ((or 'new 'edit)
       (let ((revision (plist-get options :revision)))
         (unless (and (stringp revision) (not (string-empty-p (string-trim revision))))
           (user-error "Enter a revision or @"))
         (list :commands (list (funcall command
                                        (append (list (symbol-name operation))
                                                (when (eq operation 'new) '("--message" ""))
                                                (list "--" revision)))))))
      ('bookmark
       (let ((name (plist-get options :name)))
         (unless (and (stringp name) (not (string-empty-p (string-trim name))))
           (user-error "Enter a bookmark name"))
         (list :commands (list (funcall command (list "bookmark" "set" "--revision" "@" "--" name))))))
      ('fetch (list :commands (list (funcall command '("git" "fetch")))))
      ('push (list :commands (list (funcall command '("git" "push")))))
      (_ (user-error "Unsupported jj operation: %s" operation)))))

(neo-vcs-register-backend
 'jj :program "jj" :request #'neo-vcs-jj-request
 :actions
 '((:id describe :key "c" :label "Describe current change" :input message :capture-revision t)
   (:id new :key "n" :label "New change from revision" :input revision :worktree t)
   (:id edit :key "b" :label "Edit revision" :input revision :worktree t :confirm t)
   (:id split :key "s" :label "Split selected files into a change" :target files :input message :worktree t :capture-revision t)
   (:id squash :key "S" :label "Squash selected files into parent" :target files :input message :worktree t :confirm t :capture-revision t)
   (:id restore :key "d" :label "Restore selected files from parents" :target files :worktree t :destructive t)
   (:id bookmark :key "B" :label "Set bookmark at current change" :input name)
   (:id fetch :key "f" :label "Fetch Git remote")
   (:id push :key "P" :label "Push Git remote" :confirm t)))

(provide 'neo-vcs-jj)
;;; neo-vcs-jj.el ends here
