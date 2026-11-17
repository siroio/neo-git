;;; neo-vcs-p4.el --- Perforce backend for Neo VCS -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'neo-vcs)
(require 'seq)
(require 'subr-x)

(defconst neo-vcs-p4--actions
  '((:id edit :key "e" :label "Open a file for edit" :target file :worktree t)
    (:id add :key "A" :label "Open selected files for add" :target files :worktree t)
    (:id delete :key "d" :label "Open a file for deletion" :target file
     :worktree t :destructive t)
    (:id reconcile :key "g" :label "Reconcile selected files" :target files :worktree t)
    (:id revert :key "v" :label "Revert selected opened files" :target files
     :worktree t :destructive t)
    (:id change :key "c" :label "Create an empty numbered changelist" :input message)
    (:id reopen :key "m" :label "Move selected files to a changelist" :target files :input change)
    (:id submit :key "C" :label "Submit numbered changelist (all files and any stream spec)"
     :input change :worktree t :confirm t)
    (:id sync :key "u" :label "Sync mapped workspace files" :worktree t :confirm t)
    (:id shelve :key "s" :label "Shelve selected files in a numbered changelist"
     :target files :input change :confirm t)
    (:id unshelve :key "U" :label "Unshelve files mapped in this workspace"
     :input change :worktree t :confirm t)
    (:id resolve :key "z" :label "Safely auto-resolve selected files" :target files
     :worktree t :confirm t)))

(defconst neo-vcs-p4--escapes
  '((?% . "%25") (?@ . "%40") (?# . "%23") (?* . "%2A") (?: . "%3A")))

(defconst neo-vcs-p4--local-diff-limit (* 2 1024 1024))

(defun neo-vcs-p4--command (context args &optional mode stdin)
  (let ((utf8-args (seq-filter (lambda (arg) (string-match-p "[^[:ascii:]]" arg)) args))
        (prefix (list "-Q" "utf8" "-d" (or (plist-get context :p4-directory)
                               (file-name-as-directory (plist-get context :root))))))
    (dolist (flag '((:p4-port . "-p") (:p4-client . "-c") (:p4-user . "-u")))
      (when-let* ((value (plist-get context (car flag))))
        (setq prefix (append prefix (list (cdr flag) value)))))
    ;; Windows' native argv is in the system code page.  Send non-ASCII
    ;; file arguments through P4's UTF-8 argument stream instead.
    (when utf8-args
      (unless (plist-get context :p4-unicode)
        (user-error "Non-ASCII Perforce file arguments require a Unicode server"))
      ;; -x batches operands.  Leaving ASCII file operands on argv would
      ;; repeat them in every batch, so move all file operands together.
      (setq utf8-args (seq-filter (lambda (arg) (file-name-absolute-p arg)) args))
      (when (or stdin (seq-some (lambda (arg) (string-match-p "[\r\n]" arg)) utf8-args))
        (user-error "Cannot represent this Perforce argument in a UTF-8 argument stream"))
      (setq prefix (append prefix '("-x" "-"))
            stdin (concat (string-join utf8-args "\n") "\n")
            args (seq-remove (lambda (arg) (member arg utf8-args)) args)))
    (when (and stdin (not (plist-get context :p4-unicode))
               (string-match-p "[^[:ascii:]]" stdin))
      (user-error "Non-ASCII Perforce input requires a Unicode server"))
    (list :args (append prefix (pcase mode ('script '("-s")) ('t '("-ztag" "-Mj"))) args)
          :stdin stdin)))

(defun neo-vcs-p4--records (output &optional no-work text-output)
  "Read P4's line-delimited tag records.
NO-WORK is a regexp for recognized, command-specific empty results."
  (let (records)
    (dolist (line (split-string output "\n" t))
      (unless (string-blank-p line)
        (unless (string-prefix-p "{" (string-trim-left line))
          (error "Expected a Perforce JSON object"))
        (let* ((record (neo-vcs--json line))
               (data (alist-get 'data record))
               (severity (alist-get 'severity record))
               (generic (alist-get 'generic record)))
          (cond
           ((and no-work (equal generic 17) (stringp data)
                 (string-match-p no-work (string-trim-right data))
                 (memq severity '(2 3))))
           ((and (stringp data)
                 (or (memq severity '(0 1))
                     (and (null severity)
                          (or text-output (integerp (alist-get 'level record))))))
            (push record records))
           (severity (error "Perforce: %s" (or data record)))
           ((or data (null record)) (error "Malformed Perforce record: %S" record))
           (t (push record records))))))
    (nreverse records)))

(defun neo-vcs-p4--field (record field)
  (let ((value (alist-get field record)))
    (unless (and (stringp value) (not (string-empty-p value))
                 (not (string-search "\0" value)))
      (error "Missing or invalid Perforce field %s: %S" field record))
    value))

(defun neo-vcs-p4--port (output)
  (let ((line (string-trim-right output "[\r\n]+")))
    (cond ((string-empty-p line) "perforce:1666")
          ((string-match (rx string-start "P4PORT=" (group (+ (not (any space cntrl)))) string-end) line)
           (match-string 1 line))
          (t (error "Malformed output from p4 set -q P4PORT")))))

(defun neo-vcs-p4--root (directory outputs)
  (let* ((port (neo-vcs-p4--port (car outputs)))
         (records (seq-remove (lambda (record) (assq 'data record))
                              (neo-vcs-p4--records (cadr outputs))))
         (info (car records))
         (reported (neo-vcs-p4--field info 'clientRoot))
         (client (neo-vcs-p4--field info 'clientName))
         (user (neo-vcs-p4--field info 'userName))
         (server (neo-vcs-p4--field info 'serverAddress))
         (server-id (alist-get 'serverID info)))
    (unless (and (= (length records) 1)
                 (not (string-match-p (rx (or (any "/@#*%\r\n\t") "...")) client))
                 (not (string-match-p "[\r\n\t]" user))
                 (file-name-absolute-p reported)
                 (not (file-remote-p reported))
                 (file-directory-p reported))
      (error "Perforce did not report a usable local workspace"))
    (let ((root (file-name-as-directory (file-truename reported)))
          (cwd (file-name-as-directory (expand-file-name directory))))
      (unless (or (file-equal-p cwd root) (file-in-directory-p cwd root))
        (error "Current directory is outside the Perforce workspace"))
      (list :backend 'p4 :root root :p4-directory cwd
            :id (list port server server-id client user root)
            :label (format "Perforce %s @ %s" client port)
            :p4-unicode (equal (alist-get 'unicode info) "enabled")
            :p4-port port :p4-client client :p4-user user :p4-server server))))

(defun neo-vcs-p4--client-prefix (context)
  (concat "//" (plist-get context :p4-client) "/"))

(defun neo-vcs-p4--check-path (context path)
  (let ((relative (neo-vcs--path context path)))
    (when (or (string-search "..." relative) (string-search "\uFFFD" relative)
              (and (not (eq system-type 'windows-nt)) (string-search "\\" relative)))
      (error "Cannot express this Perforce file as a literal filespec: %s" relative))
    relative))

(defun neo-vcs-p4--filespec (context relative)
  (concat (neo-vcs-p4--client-prefix context)
          (replace-regexp-in-string
           "[%@#*:]" (lambda (match) (alist-get (aref match 0) neo-vcs-p4--escapes))
           relative t t)))

(defun neo-vcs-p4--entry-path (context record)
  (let* ((path (neo-vcs-p4--field record 'clientFile))
         (prefix (neo-vcs-p4--client-prefix context))
         (root (plist-get context :root))
         (relative
          (cond
           ((string-prefix-p prefix path)
            (let ((case-fold-search t))
              (replace-regexp-in-string
               (rx "%" (or "25" "40" "23" "2a" "3a"))
               (lambda (match)
                 (char-to-string (car (rassoc (upcase match) neo-vcs-p4--escapes))))
               (substring path (length prefix)) t t)))
           ((string-prefix-p "//" path)
            (error "Perforce returned a path in another client: %s" path))
           ((and (file-name-absolute-p path) (not (file-remote-p path))
                 (file-in-directory-p path root))
            (file-relative-name path root))
           (t (error "Perforce returned an invalid local path: %s" path)))))
    (when (string-search "\uFFFD" relative)
      (error "P4 JSON cannot represent this filename; use a Unicode server with UTF-8 command encoding: %s" relative))
    (neo-vcs--path context relative)))

(defun neo-vcs-p4--change-number (value &optional default)
  (unless (and (stringp value)
               (or (and default (equal value "default"))
                   (string-match-p (rx string-start (any "1-9") (* digit) string-end) value)))
    (user-error "Enter %sPerforce changelist number"
                (if default "default or a positive " "a positive ")))
  value)

(defun neo-vcs-p4--entry (context record opened)
  (let* ((path (neo-vcs-p4--entry-path context record))
         (action (neo-vcs-p4--field record 'action))
         (change (and opened
                      (neo-vcs-p4--change-number (neo-vcs-p4--field record 'change) t)))
         (status (pcase action
                   ((or "add" "move/add" "branch" "import") (if opened 'added 'untracked))
                   ((or "delete" "move/delete") (if opened 'deleted 'missing))
                   ((or "edit" "integrate" "archive" "purge") 'modified)
                   (_ (error "Unexpected Perforce action: %s" action)))))
    (list :path path :status status :group
          (cond ((equal change "default") "Default change")
                (change (concat "Change " change))
                (t "Unopened"))
          :p4-change change :p4-open (and opened action)
          :p4-preview (unless opened action))))

(defun neo-vcs-p4--status (context outputs)
  (let* ((empty-open (rx (or "F" "f") "ile(s) not opened on this client." string-end))
         (opened (neo-vcs-p4--records (nth 0 outputs) empty-open))
        (preview (neo-vcs-p4--records
                  (nth 1 outputs) (rx "No file(s) to reconcile." string-end)))
        (unresolved (neo-vcs-p4--records
                     (nth 2 outputs) (concat empty-open "\\|"
                                              (rx " - no such file(s)." string-end))))
        (by-path (make-hash-table :test #'equal))
        entries)
    (dolist (set (list (cons t opened) (cons nil preview)))
      (dolist (record (cdr set))
        (unless (assq 'data record)
          (let* ((entry (neo-vcs-p4--entry context record (car set)))
                 (path (plist-get entry :path)))
            (unless (gethash path by-path)
              (puthash path entry by-path)
              (push entry entries))))))
    (dolist (record unresolved)
      (unless (assq 'data record)
        (let ((entry (gethash (neo-vcs-p4--entry-path context record) by-path)))
          (when entry
            (setf (plist-get entry :status) 'conflict)))))
    (list :label (or (plist-get context :label) (plist-get context :p4-client))
          :entries (nreverse entries))))

(defun neo-vcs-p4--history (outputs)
  (let (history)
    (dolist (record (neo-vcs-p4--records (car outputs) (rx " - no such file(s)." string-end)))
      (unless (assq 'data record)
        (let ((id (neo-vcs-p4--change-number (neo-vcs-p4--field record 'change)))
              (time (neo-vcs-p4--field record 'time))
              (author (neo-vcs-p4--field record 'user))
              (description (alist-get 'desc record)))
          (unless (and (string-match-p (rx string-start (+ digit) string-end) time)
                       (equal (alist-get 'status record) "submitted")
                       (stringp description))
            (error "Malformed Perforce changelist: %S" record))
          (push (list :id id :short id :author author
                      :date (format-time-string "%Y-%m-%d" (string-to-number time) t)
                      :subject (car (split-string (string-trim description) "\n")))
                history))))
    (nreverse history)))

(defun neo-vcs-p4--one-sided-diff (path content added)
  (let* ((terminated (string-suffix-p "\n" content))
         (body (if terminated (substring content 0 -1) content))
         (lines (unless (string-empty-p content) (split-string body "\n")))
         (display-path (if (string-match-p "[\t\r\n]" path)
                           (let ((print-escape-newlines t)
                                 (print-escape-control-characters t))
                             (prin1-to-string path))
                         path))
         (old (if added "/dev/null" (concat "a/" display-path)))
         (new (if added (concat "b/" display-path) "/dev/null"))
         (start (format "1,%d" (length lines))))
    (cond
     ((string-search "\0" content) (format "Binary files %s and %s differ\n" old new))
     ((null lines) (format "--- %s\n+++ %s\n" old new))
     (t
      (concat (format "--- %s\n+++ %s\n@@ -%s +%s @@\n"
                      old new (if added "0,0" start) (if added start "0,0"))
              (mapconcat (lambda (line) (concat (if added "+" "-") line "\n")) lines)
              (unless terminated "\\ No newline at end of file\n"))))))

(defun neo-vcs-p4--diff-data (records)
  (mapconcat (lambda (record)
               (cond ((alist-get 'data record))
                     ((alist-get 'depotFile record)
                      (format "==== %s#%s ====\n"
                              (neo-vcs-p4--field record 'depotFile)
                              (neo-vcs-p4--field record 'rev)))
                     (t (error "Unexpected Perforce diff record: %S" record))))
             records ""))

(defun neo-vcs-p4--describe (id outputs)
  ;; Tagged describe returns the change metadata but suppresses diff hunks.
  (let* ((lines (split-string (car outputs) "\r?\n" t))
         (header (car lines)))
    (unless (and (equal (car (last lines)) "exit: 0")
                 (string-prefix-p (format "text: Change %s by " id) (or header ""))
                 (not (string-search "*pending*" header)))
      (if-let* ((diagnostic (seq-find (lambda (line) (string-match-p (rx bol (or "error:" "warning:"))
                                                                     line))
                                      lines)))
          (error "Perforce: %s" diagnostic)
        (error "Expected submitted Perforce changelist %s" id)))
    (concat
     (mapconcat
      (lambda (line)
        (cond ((string-prefix-p "text: " line) (substring line 6))
              ((string-prefix-p "info1: " line) (concat "... " (substring line 7)))
              ((string-prefix-p "info: " line) (substring line 6))
              (t (error "Unexpected Perforce describe output: %s" line))))
      (butlast lines) "\n")
     "\n")))

(defun neo-vcs-p4--deleted-diff (path outputs)
  (let* ((records (neo-vcs-p4--records (car outputs) nil t))
         (info (car records))
         (type (neo-vcs-p4--field info 'type)))
    (neo-vcs-p4--field info 'depotFile)
    (if (string-match-p (rx string-start (or "text" "unicode" "utf8" "utf16" "symlink")) type)
        (neo-vcs-p4--one-sided-diff
         path (mapconcat (lambda (record)
                           (or (alist-get 'data record)
                               (error "Unexpected Perforce file content: %S" record)))
                         (cdr records) "") nil)
      (format "Binary file deleted: %s\n" path))))

(defun neo-vcs-p4--diff (context target)
  (let* ((path (neo-vcs-p4--check-path context (plist-get target :path)))
         (spec (concat (neo-vcs-p4--filespec context path) "#have")))
    (pcase (plist-get target :status)
      ((or 'added 'untracked)
       (list :commands nil :parse
             (lambda (_)
               (let* ((file (expand-file-name (neo-vcs--path context path)
                                              (plist-get context :root)))
                      (size (file-attribute-size (file-attributes file))))
                 (unless (and (file-regular-p file) (integerp size)
                              (<= size neo-vcs-p4--local-diff-limit))
                   (error "Cannot display added Perforce file: %s" path))
                 (with-temp-buffer
                   (insert-file-contents file nil 0 (1+ neo-vcs-p4--local-diff-limit))
                   (when (> (position-bytes (point-max)) (1+ neo-vcs-p4--local-diff-limit))
                     (error "Added Perforce file exceeds diff size limit: %s" path))
                   (neo-vcs-p4--one-sided-diff path (buffer-string) t))))))
      ((or 'deleted 'missing)
       (list :commands (list (neo-vcs-p4--command context (list "print" "-q" "-K" spec) t))
             :parse (apply-partially #'neo-vcs-p4--deleted-diff path)))
      (_ (list :commands (list (neo-vcs-p4--command context (list "diff" "-f" "-du" spec) t))
               :parse (lambda (outputs)
                        (neo-vcs-p4--diff-data (neo-vcs-p4--records (car outputs) nil t))))))))

(defun neo-vcs-p4--action-output (operation outputs)
  (let (messages)
    (dolist (output outputs)
      (dolist (record
               (neo-vcs-p4--records
                output (pcase operation
                         ('sync (rx "file(s) up-to-date." string-end))
                         ('resolve (rx "file(s) to resolve." string-end)))))
        (when-let* ((message (alist-get 'data record)))
          ;; Native delete can refuse a moved file with exit 0 and level 0.
          ;; Status metadata is only a snapshot; another client can change it.
          (when (and (eq operation 'delete)
                     (string-match-p (rx " - can't delete (" (* nonl) ")" string-end)
                                     (string-trim-right message)))
            (error "%s" (string-trim-right message)))
          (push (string-trim-right message) messages))))
    (when messages (string-join (nreverse messages) "\n"))))

(defun neo-vcs-p4--created-change (outputs)
  (let ((output (car outputs)))
    (unless (string-match-p (rx bol "Change " (+ digit) " created" (or "." eol)) output)
      (error "Perforce did not create a changelist: %s" output))
    output))

(defun neo-vcs-p4--add-args (context paths)
  (mapcar (lambda (path)
            (let ((absolute (expand-file-name path (plist-get context :root))))
              ;; -f handles revision characters in a new file. Wildcards in
              ;; local search arguments can still select other files.
              (when (string-match-p (rx (or "*" "...")) absolute)
                (user-error "Perforce cannot safely add this literal path: %s" path))
              absolute))
          paths))

(defun neo-vcs-p4--action (context operation target options)
  (let* ((action (seq-find (lambda (item) (eq (plist-get item :id) operation))
                           neo-vcs-p4--actions))
         (target-type (plist-get action :target))
         (raw-paths (when target (neo-vcs--paths context target)))
         (paths (mapcar (lambda (path) (neo-vcs-p4--check-path context path)) raw-paths))
         (specs (mapcar (lambda (path) (neo-vcs-p4--filespec context path)) paths))
         (scope (concat (neo-vcs-p4--client-prefix context) "..."))
         (change (plist-get options :change))
         command)
    (unless action (error "Unsupported Perforce operation: %s" operation))
    (unless (pcase target-type ('file (= (length specs) 1)) ('files specs) (_ (null target)))
      (user-error "Invalid file selection for Perforce %s" operation))
    (when (and (memq operation '(delete revert reopen resolve))
               (seq-some (lambda (entry)
                           (string-prefix-p "move/" (or (plist-get entry :p4-open) "")))
                         target))
      (user-error "Perforce %s on a move pair requires handling both sides together" operation))
    (setq command
          (pcase operation
            ('change
             (let ((message (plist-get options :message)))
               (unless (and (stringp message) (not (string-blank-p message))
                            (not (string-match-p "[\0\r]" message)))
                 (user-error "Enter a Perforce changelist description"))
               (neo-vcs-p4--command
                context '("change" "-i") nil
                (format "Change: new\n\nDescription:\n%s\n"
                        (mapconcat (lambda (line) (concat "\t" line))
                                   (split-string message "\n") "\n")))))
            (_
             (neo-vcs-p4--command
              context
              (pcase operation
                ('add (cons "add" (cons "-f" (neo-vcs-p4--add-args context paths))))
                ('reconcile
                 (when (seq-some (lambda (entry)
                                   (and (equal (plist-get entry :p4-preview) "add")
                                        (string-match-p "[%@#*:]" (plist-get entry :path))))
                                 target)
                   (user-error "Use Add for new Perforce files with special characters"))
                 (cons "reconcile" specs))
                ('reopen (append (list "reopen" "-c" (neo-vcs-p4--change-number change t)) specs))
                ('submit (list "submit" "-c" (neo-vcs-p4--change-number change)))
                ('sync (list "sync" scope))
                ('shelve
                 (neo-vcs-p4--change-number change)
                 (unless (seq-every-p (lambda (entry) (equal (plist-get entry :p4-change) change))
                                      target)
                   (user-error "Selected files must belong to changelist %s" change))
                 (append (list "shelve" "-Af" "-c" change) specs))
                ('unshelve (list "unshelve" "-Af" "-s" (neo-vcs-p4--change-number change) scope))
                ('resolve (append '("resolve" "-as") specs))
                (_ (cons (symbol-name operation) specs)))
              t))))
    (list :commands (list command)
          :parse (if (eq operation 'change)
                     #'neo-vcs-p4--created-change
                   (apply-partially #'neo-vcs-p4--action-output operation)))))

(defun neo-vcs-p4-request (context operation &optional target options)
  "Build a Perforce request for OPERATION in CONTEXT with TARGET and OPTIONS."
  (let ((scope (concat (neo-vcs-p4--client-prefix context) "...")))
    (pcase operation
      ('root
       (list :commands (list (neo-vcs-p4--command context '("set" "-q" "P4PORT"))
                             (neo-vcs-p4--command context '("info") t))
             :parse (apply-partially #'neo-vcs-p4--root (plist-get context :root))))
      ('status
       (list :commands
             (list (neo-vcs-p4--command context (list "opened" scope) t)
                   (neo-vcs-p4--command context (list "reconcile" "-n" "-f" scope) t)
                   (neo-vcs-p4--command context (list "fstat" "-Ru" "-T" "clientFile,depotFile" scope) t))
             :parse (apply-partially #'neo-vcs-p4--status context)))
      ('history
       (list :commands
             (list (neo-vcs-p4--command context (list "changes" "-s" "submitted" "-m" "100" scope) t))
             :parse #'neo-vcs-p4--history))
      ('diff (neo-vcs-p4--diff context target))
      ('show
       (let ((id (neo-vcs-p4--change-number (plist-get target :id))))
         (list :commands (list (neo-vcs-p4--command context (list "describe" "-du" id) 'script))
               :parse (apply-partially #'neo-vcs-p4--describe id))))
      (_ (neo-vcs-p4--action context operation target options)))))

(neo-vcs-register-backend 'p4 :program "p4" :request #'neo-vcs-p4-request
                          :actions neo-vcs-p4--actions :environment '("P4DIFF=" "DIFF="))

(provide 'neo-vcs-p4)
;;; neo-vcs-p4.el ends here
