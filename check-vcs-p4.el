;;; check-vcs-p4.el --- Perforce backend checks -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'seq)

;; Delay loading so the request tests can be run before the backend exists.
(defun neo-vcs-p4-test--request (context operation &optional target options)
  (require 'neo-vcs-p4)
  (neo-vcs-p4-request context operation target options))

(defmacro neo-vcs-p4-test--workspace (&rest body)
  `(let* ((root (file-name-as-directory (make-temp-file "neo-p4-" t)))
          (context (list :backend 'p4 :root root :p4-directory root
                         :p4-unicode t
                         :p4-port "ssl:broker.example.invalid:1666"
                         :p4-user "echo" :p4-client "echo-ws")))
     (unwind-protect (progn ,@body)
       (delete-directory root t))))

(defun neo-vcs-p4-test--parse (request &rest outputs)
  (funcall (plist-get request :parse) outputs))

(defun neo-vcs-p4-test--args (request command)
  (seq-find (lambda (args) (member command args))
            (mapcar (lambda (step) (plist-get step :args))
                    (plist-get request :commands))))

(ert-deftest neo-vcs-p4-root-retains-client-and-effective-transport ()
  (neo-vcs-p4-test--workspace
   (let* ((sub (expand-file-name "nested" root))
          (_ (make-directory sub))
          (request (neo-vcs-p4-test--request (list :backend 'p4 :root sub) 'root))
          (info (format (concat "{\"clientName\":\"echo-ws\",\"clientRoot\":%s,"
                                "\"userName\":\"echo\",\"serverAddress\":\"edge.internal:1666\","
                                "\"serverID\":\"edge-eu\"}\n")
                        (json-serialize (directory-file-name root))))
          (detected (neo-vcs-p4-test--parse request
                                           "P4PORT=ssl:broker.example.invalid:1666\n" info))
          (args (neo-vcs-p4-test--args (neo-vcs-p4-test--request detected 'history) "changes")))
     (should (equal (plist-get detected :root) (file-truename root)))
     (should (equal (plist-get detected :p4-server) "edge.internal:1666"))
     (should (equal (cadr (member "-p" args)) "ssl:broker.example.invalid:1666"))
     (should (equal (cadr (member "-c" args)) "echo-ws"))
     (should (equal (cadr (member "-u" args)) "echo"))
     (should (equal (cadr (member "-d" args)) (file-name-as-directory sub)))
     (should-error (neo-vcs-p4-test--parse request "" "{\"clientName\":\"*unknown*\"}\n"))
     (should-error (neo-vcs-p4-test--parse
                    (neo-vcs-p4-test--request
                     (list :backend 'p4 :root (file-name-directory (directory-file-name root))) 'root)
                    "" info)))))

(ert-deftest neo-vcs-p4-status-keeps-opened-changelists-and-previews-distinct ()
  (neo-vcs-p4-test--workspace
   (let* ((request (neo-vcs-p4-test--request context 'status))
          (opened (concat "{\"depotFile\":\"//stream/main/編集%40%23%25%2A.txt\","
                          "\"clientFile\":\"//echo-ws/編集%40%23%25%2A.txt\","
                          "\"change\":\"142\",\"action\":\"edit\",\"type\":\"text\"}\n"
                          "{\"depotFile\":\"//stream/main/moved.txt\","
                          "\"clientFile\":\"//echo-ws/moved.txt\",\"change\":\"default\","
                          "\"action\":\"move/add\"}\n"))
          (preview (concat "{\"depotFile\":\"//stream/main/edited.txt\","
                           "\"clientFile\":\"//echo-ws/edited.txt\",\"action\":\"edit\"}\n"
                           "{\"depotFile\":\"//stream/main/missing.txt\","
                           "\"clientFile\":\"//echo-ws/missing.txt\",\"action\":\"delete\"}\n"
                           "{\"depotFile\":\"//stream/main/new name.txt\","
                           "\"clientFile\":\"//echo-ws/new name.txt\",\"action\":\"add\"}\n"
                           "{\"depotFile\":\"//stream/main/moved.txt\","
                           "\"clientFile\":\"//echo-ws/moved.txt\",\"action\":\"delete\"}\n"))
          (unresolved (format "{\"depotFile\":\"//stream/main/編集%%40%%23%%25%%2A.txt\",\"clientFile\":%s}\n"
                              (decode-coding-string
                               (json-serialize (expand-file-name "編集@#%*.txt" root)) 'utf-8)))
          (entries (plist-get (neo-vcs-p4-test--parse request opened preview unresolved) :entries))
          (reconcile (neo-vcs-p4-test--args request "reconcile")))
     (should (member "-n" reconcile))
     (should (member "//echo-ws/..." reconcile))
     (should (equal (mapcar (lambda (entry) (plist-get entry :path)) entries)
                    '("編集@#%*.txt" "moved.txt" "edited.txt" "missing.txt" "new name.txt")))
     (should (equal (mapcar (lambda (entry) (plist-get entry :status)) entries)
                    '(conflict added modified missing untracked)))
     (should (equal (mapcar (lambda (entry) (plist-get entry :group)) entries)
                    '("Change 142" "Default change" "Unopened" "Unopened" "Unopened"))))))

(ert-deftest neo-vcs-p4-status-rejects-invalid-records-and-accepts-no-work ()
  (neo-vcs-p4-test--workspace
   (let ((request (neo-vcs-p4-test--request context 'status)))
     (should-not
      (plist-get (neo-vcs-p4-test--parse
                  request
                  ""
                  "{\"data\":\"//echo-ws/... - no file(s) to reconcile.\\n\",\"generic\":17,\"severity\":2}\n"
                  "{\"data\":\"//echo-ws/... - file(s) not opened on this client.\\n\",\"generic\":17,\"severity\":2}\n") :entries))
     (should-error (neo-vcs-p4-test--parse
                    request "" "{\"data\":\"Password invalid.\\n\",\"generic\":6,\"severity\":3}\n" ""))
     (should-error (neo-vcs-p4-test--parse request "{}\n" "" ""))
     (should-error (neo-vcs-p4-test--parse request "[]\n" "" ""))
     (should-error (neo-vcs-p4-test--parse
                    request "" "{\"clientFile\":\"//other/unrelated.txt\",\"action\":\"add\"}\n" ""))
     (should-error (neo-vcs-p4-test--parse
                    request "" "{\"clientFile\":\"//echo-ws/../escape.txt\",\"action\":\"add\"}\n" "")))))

(ert-deftest neo-vcs-p4-file-arguments-encode-literals-and-reject-ellipsis ()
  (neo-vcs-p4-test--workspace
   (let* ((file (list :path "- spaced/資料@#%*.c"))
          (edit (neo-vcs-p4-test--request context 'edit (list file))))
     (should (equal (plist-get (car (plist-get edit :commands)) :stdin)
                    "//echo-ws/- spaced/資料%40%23%25%2A.c\n"))
     (should (member "-x" (neo-vcs-p4-test--args edit "edit")))
     (dolist (operation '(edit add delete reconcile revert reopen shelve resolve))
       (dolist (path '("dir/.../file" "prefix....txt" "../escape"))
         (should-error
          (neo-vcs-p4-test--request context operation (list (list :path path))
                                    '(:change "142"))))
       (should-error (neo-vcs-p4-test--request context operation nil '(:change "142"))))
     (let* ((path "- new 亜@#%.txt")
            (new (list :path path :status 'untracked :p4-preview "add"))
            (add (neo-vcs-p4-test--request context 'add (list new))))
       (should (equal (member "add" (neo-vcs-p4-test--args add "add")) '("add" "-f")))
       (should (equal (plist-get (car (plist-get add :commands)) :stdin)
                      (concat (expand-file-name path root) "\n")))))))

(ert-deftest neo-vcs-p4-unicode-paths-use-one-complete-argument-stream ()
  (neo-vcs-p4-test--workspace
   (let* ((request (neo-vcs-p4-test--request context 'revert '((:path "ascii.txt") (:path "名前.txt"))))
          (step (car (plist-get request :commands))))
     (should (equal (member "revert" (plist-get step :args)) '("revert")))
     (should (equal (plist-get step :stdin) "//echo-ws/ascii.txt\n//echo-ws/名前.txt\n")))
   (should-error (neo-vcs-p4-test--request context 'revert '((:path "名前\nextra.txt"))))
   (setq context (plist-put context :p4-unicode nil))
   (should-error (neo-vcs-p4-test--request context 'add '((:path "名前.txt"))))
   (should-error (neo-vcs-p4-test--request context 'change nil '(:message "変更")))))

(ert-deftest neo-vcs-p4-history-and-diff-requests-use-workspace-and-verified-ids ()
  (neo-vcs-p4-test--workspace
   (let* ((request (neo-vcs-p4-test--request context 'history))
          (history (neo-vcs-p4-test--parse
                    request (concat "{\"change\":\"143\",\"time\":\"1735689600\","
                                    "\"user\":\"echo\",\"client\":\"echo-ws\","
                                    "\"status\":\"submitted\",\"desc\":\"入力修正\\nDetails\\n\"}\n")))
          (show (neo-vcs-p4-test--request context 'show (car history)))
          (patch "@@ -1 +1 @@\n-a\n+b\n")
          (json-patch "{\"data\":\"@@ -1 +1 @@\\n-a\\n+b\\n\"}\n"))
     (should (member "//echo-ws/..." (neo-vcs-p4-test--args request "changes")))
     (should (equal (car history) '(:id "143" :short "143" :author "echo" :date "2025-01-01" :subject "入力修正")))
     (should (equal (member "describe" (neo-vcs-p4-test--args show "describe")) '("describe" "-du" "143")))
     (should (member "-s" (neo-vcs-p4-test--args show "describe")))
     (should (string-suffix-p
              patch (neo-vcs-p4-test--parse
                     show (concat "text: Change 143 by echo@echo-ws on 2025/01/01 00:00:00\n"
                                  "text: \ntext: \tSummary\n"
                                  "info1: //depot/change%40.txt#2 edit\n"
                                  "text: @@ -1 +1 @@\ntext: -a\ntext: +b\nexit: 0\n"))))
     (should-error (neo-vcs-p4-test--request context 'show '(:id "143\n141")))
     (should-error (neo-vcs-p4-test--parse
                    show "warning: 143 - no such changelist.\nexit: 0\n"))
     (let ((diff (neo-vcs-p4-test--request context 'diff '(:path "change@.txt" :status modified))))
       (should (equal (car (last (neo-vcs-p4-test--args diff "diff"))) "//echo-ws/change%40.txt#have"))
       (should (string-suffix-p
                patch (neo-vcs-p4-test--parse
                       diff (concat "{\"depotFile\":\"//depot/change%40.txt\",\"type\":\"text\",\"rev\":\"1\"}\n"
                                    json-patch))))))))

(ert-deftest neo-vcs-p4-add-and-delete-diffs-include-file-contents ()
  (neo-vcs-p4-test--workspace
   (let* ((name "新規.txt")
          (new (neo-vcs-p4-test--request context 'diff (list :path name :status 'untracked)))
          (missing (neo-vcs-p4-test--request context 'diff '(:path "missing.txt" :status missing))))
     (write-region "新規\nlast" nil (expand-file-name name root))
     (should (string-match-p (regexp-quote "@@ -0,0 +1,2 @@\n+新規\n+last\n\\ No newline at end of file\n")
                             (neo-vcs-p4-test--parse new)))
     (should (equal (car (last (neo-vcs-p4-test--args missing "print"))) "//echo-ws/missing.txt#have"))
     (should (string-match-p (regexp-quote "@@ -1,1 +0,0 @@\n-original\n")
                             (neo-vcs-p4-test--parse
                              missing (concat "{\"depotFile\":\"//depot/missing.txt\",\"type\":\"text\",\"rev\":\"1\"}\n"
                                              "{\"data\":\"original\\n\"}\n{\"data\":\"\"}\n")))))))

(ert-deftest neo-vcs-p4-mutations-limit-arguments-and-require-valid-changes ()
  (neo-vcs-p4-test--workspace
   (let* ((file '(:path "open.txt" :p4-open "edit" :p4-change "142"))
          (reopen (neo-vcs-p4-test--request context 'reopen (list file) '(:change "default")))
          (shelve (neo-vcs-p4-test--request context 'shelve (list file) '(:change "142")))
          (submit (neo-vcs-p4-test--request context 'submit nil '(:change "142")))
          (sync (neo-vcs-p4-test--request context 'sync))
          (unshelve (neo-vcs-p4-test--request context 'unshelve nil '(:change "142")))
          (resolve (neo-vcs-p4-test--request context 'resolve (list file)))
          (create (neo-vcs-p4-test--request context 'change nil '(:message "Title\nFiles:\n\t//other/..."))))
     (should (equal (member "reopen" (neo-vcs-p4-test--args reopen "reopen"))
                    '("reopen" "-c" "default" "//echo-ws/open.txt")))
     (should (equal (member "shelve" (neo-vcs-p4-test--args shelve "shelve"))
                    '("shelve" "-Af" "-c" "142" "//echo-ws/open.txt")))
     (should (equal (member "submit" (neo-vcs-p4-test--args submit "submit")) '("submit" "-c" "142")))
     (should (equal (member "sync" (neo-vcs-p4-test--args sync "sync")) '("sync" "//echo-ws/...")))
     (should (equal (member "unshelve" (neo-vcs-p4-test--args unshelve "unshelve"))
                    '("unshelve" "-Af" "-s" "142" "//echo-ws/...")))
     (should (equal (member "resolve" (neo-vcs-p4-test--args resolve "resolve"))
                    '("resolve" "-as" "//echo-ws/open.txt")))
     (let ((form (plist-get (car (plist-get create :commands)) :stdin)))
       (should (string-match-p (regexp-quote "\tTitle\n\tFiles:\n\t\t//other/...\n") form))
       (should-not (string-match-p "^Files:" form)))
     (dolist (change '(nil "0" "-1" "142 ..."))
       (should-error (neo-vcs-p4-test--request context 'submit nil (list :change change))))
     (should-error (neo-vcs-p4-test--request context 'submit (list file) '(:change "142")))
     (should-error (neo-vcs-p4-test--request context 'shelve (list file) '(:change "143")))
     (should-error (neo-vcs-p4-test--request context 'revert '((:path "paired.txt" :p4-open "move/add")))))))

(ert-deftest neo-vcs-p4-delete-reports-native-level-zero-refusal ()
  (neo-vcs-p4-test--workspace
   (let ((request (neo-vcs-p4-test--request context 'delete '((:path "after.txt")))))
     ;; P4 2026.1 returns exit 0 for a stale selection now opened for move/add.
     (should-error
      (neo-vcs-p4-test--parse
       request "{\"data\":\"//depot/after.txt - can't delete (already opened for move/add)\",\"level\":0}\n")))))

(defun neo-vcs-p4-test--live-request (context operation &optional target options)
  (let ((request (neo-vcs-p4-test--request context operation target options))
        (deadline (+ (float-time) 20))
        reply)
    (with-temp-buffer
      (neo-vcs--execute context request
                        (lambda (status data errors) (setq reply (list status data errors))))
      (while (and (null reply) (< (float-time) deadline))
        (accept-process-output nil 0.05))
      (when (null reply)
        (neo-vcs--cancel-reads)
        (ert-fail (list operation "Perforce did not respond"))))
    (unless (eql (car reply) 0)
      (ert-fail (list operation (car reply) (nth 2 reply))))
    (nth 1 reply)))

(defun neo-vcs-p4-test--live-change (context message)
  (let ((output (neo-vcs-p4-test--live-request context 'change nil (list :message message))))
    (should (string-match (rx "Change " (group (+ digit)) " created") output))
    (list :change (match-string 1 output))))

(ert-deftest neo-vcs-p4-live-isolated-workflow ()
  ;; The developer harness starts a fresh, authenticated loopback server and
  ;; injects an empty client workspace and its bundled tools below var/.
  (let* ((root (getenv "NEO_P4_TEST_WORKSPACE"))
         (tools (getenv "NEO_P4_TEST_TOOLS"))
         (var (expand-file-name "var/multi-vcs" default-directory))
         (port (getenv "P4PORT")))
    (skip-unless (and root tools port))
    (require 'check-vcs-test-helper)
    (setq root (expand-file-name root) tools (expand-file-name tools))
    (should (file-in-directory-p root var))
    (should (file-in-directory-p tools var))
    (should (string-match-p (rx string-start "127.0.0.1:" (+ digit) string-end) port))
    (let* ((exec-path (cons tools exec-path))
           (context (neo-vcs-p4-test--live-request (list :backend 'p4 :root root) 'root))
           (opened-name (if (getenv "NEO_P4_TEST_UNICODE") "編集opened@#%.txt" "opened@#%.txt"))
           (seed-label (if (getenv "NEO_P4_TEST_UNICODE") "初回" "Seed"))
           (files (list '(:path "edited.txt") '(:path "missing.txt") (list :path opened-name))))
      (should (eq (plist-get context :p4-unicode) (and (getenv "NEO_P4_TEST_UNICODE") t)))
      (should (equal (plist-get context :root) (file-name-as-directory (file-truename root))))
      (should-not (plist-get (neo-vcs-p4-test--live-request context 'status) :entries))
      (should-not (neo-vcs-p4-test--live-request context 'history))
      (neo-vcs-test-open context)
      (dolist (file files)
        (write-region "before\n" nil (expand-file-name (plist-get file :path) root)))
      (neo-vcs-p4-test--live-request context 'add files)
      (let ((change (neo-vcs-p4-test--live-change context (concat seed-label "\nSecond line"))))
        (neo-vcs-p4-test--live-request context 'reopen files change)
        (neo-vcs-p4-test--live-request context 'submit nil change))
      (neo-vcs-p4-test--live-request context 'sync)
      (neo-vcs-p4-test--live-request context 'edit (last files))
      (write-region "after\n" nil (expand-file-name opened-name root))
      (set-file-modes (expand-file-name "edited.txt" root) #o644)
      (write-region "after\n" nil (expand-file-name "edited.txt" root))
      (set-file-modes (expand-file-name "missing.txt" root) #o644)
      (delete-file (expand-file-name "missing.txt" root))
      (write-region "new\n" nil (expand-file-name "new @#%.txt" root))
      (let* ((entries (plist-get (neo-vcs-p4-test--live-request context 'status) :entries))
             (entries-by-path (mapcar (lambda (entry) (cons (plist-get entry :path) entry)) entries))
             (history (neo-vcs-p4-test--live-request context 'history))
             (modified (cdr (assoc "edited.txt" entries-by-path)))
             (missing (cdr (assoc "missing.txt" entries-by-path)))
             (new (cdr (assoc "new @#%.txt" entries-by-path)))
             (opened (cdr (assoc opened-name entries-by-path)))
             (change (neo-vcs-p4-test--live-change context "Pending")))
        (should (equal (plist-get (car history) :subject) seed-label))
        (should (string-match-p "Change " (neo-vcs-p4-test--live-request context 'show (car history))))
        (should (eq (plist-get modified :status) 'modified))
        (should (eq (plist-get missing :status) 'missing))
        (should (eq (plist-get new :status) 'untracked))
        (should (equal (plist-get opened :group) "Default change"))
        (should (string-match-p (regexp-quote "+after\n")
                                (neo-vcs-p4-test--live-request context 'diff modified)))
        (should (string-match-p (regexp-quote "-before\n")
                                (neo-vcs-p4-test--live-request context 'diff missing)))
        (neo-vcs-p4-test--live-request context 'reconcile (list modified missing))
        (neo-vcs-p4-test--live-request context 'reopen (list opened) change)
        (let* ((pending (plist-get (neo-vcs-p4-test--live-request context 'status) :entries))
               (numbered (seq-find (lambda (entry) (eq (plist-get entry :status) 'modified))
                                   (seq-filter (lambda (entry) (equal (plist-get entry :p4-change)
                                                                    (plist-get change :change)))
                                               pending))))
          (should numbered)
          (neo-vcs-p4-test--live-request context 'shelve (list numbered) change)
          (neo-vcs-p4-test--live-request context 'revert (list numbered))
          (neo-vcs-p4-test--live-request context 'edit (list numbered))
          (neo-vcs-p4-test--live-request context 'unshelve nil change)
          (let ((conflict (seq-find (lambda (entry)
                                      (equal (plist-get entry :path) opened-name))
                                    (plist-get (neo-vcs-p4-test--live-request context 'status)
                                               :entries))))
            (should (eq (plist-get conflict :status) 'conflict))
            (neo-vcs-p4-test--live-request context 'resolve (list conflict)))
          (should (string-match-p (regexp-quote "+after\n")
                                  (neo-vcs-p4-test--live-request context 'diff opened)))
          (neo-vcs-p4-test--live-request context 'add (list new))
          (neo-vcs-p4-test--live-request context 'revert (list modified))
          (neo-vcs-p4-test--live-request context 'delete (list '(:path "edited.txt")))
          (should-not (file-exists-p (expand-file-name "edited.txt" root)))
          (let ((deleted (seq-find (lambda (entry) (equal (plist-get entry :path) "edited.txt"))
                                   (plist-get (neo-vcs-p4-test--live-request context 'status)
                                              :entries))))
            (should (eq (plist-get deleted :status) 'deleted))
            (should (string-match-p (regexp-quote "-before\n")
                                    (neo-vcs-p4-test--live-request context 'diff deleted))))
          (let ((final (neo-vcs-p4-test--live-change context "Publish one file")))
            (neo-vcs-p4-test--live-request context 'reopen (list opened) final)
            (neo-vcs-p4-test--live-request context 'submit nil final)
            (let* ((latest (car (neo-vcs-p4-test--live-request context 'history)))
                   (patch (neo-vcs-p4-test--live-request context 'show latest)))
              (should (equal (plist-get latest :subject) "Publish one file"))
              (when (getenv "NEO_P4_TEST_UNICODE") (should (string-match-p "編集opened" patch)))
              (should (string-match-p (regexp-quote "+after\n") patch))
              (should-not (string-match-p "edited.txt" patch)))))))))

;;; check-vcs-p4.el ends here
