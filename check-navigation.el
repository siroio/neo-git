;;; check-navigation.el --- Selection boundaries -*- lexical-binding: t; -*-
(load (expand-file-name "neo-git.el" (file-name-directory load-file-name)) nil t)
(require 'ert)

(defun neo-git-navigation-command (command)
  (run-hooks 'pre-command-hook)
  (funcall command)
  (run-hooks 'post-command-hook))

(defun neo-git-navigation-status ()
  (neo-git-mode)
  (setq neo-git-entries
        '((:path "first" :kind unstaged)
          (:path "second" :kind unstaged)
          (:path "last" :kind staged)))
  (neo-git--render))

(ert-deftest neo-git-navigation-status-bounds ()
  (with-temp-buffer
    (neo-git-navigation-status)
    (neo-git-navigation-command #'end-of-buffer)
    (should (equal (plist-get (neo-git--entry-at-point) :path) "last"))
    (neo-git-navigation-command #'beginning-of-buffer)
    (should (equal (plist-get (neo-git--entry-at-point) :path) "first"))))

(ert-deftest neo-git-navigation-outside-next-previous ()
  (dolist (command '(neo-git-next neo-git-previous))
    (with-temp-buffer
      (neo-git-navigation-status)
      (goto-char (point-max))
      (funcall command)
      (should (equal (plist-get (neo-git--entry-at-point) :path) "last")))))

(ert-deftest neo-git-navigation-heading-and-preview ()
  (with-temp-buffer
    (neo-git-navigation-status)
    (neo-git-next)
    (neo-git-navigation-command (lambda () (forward-line 1)))
    (should (equal (plist-get (neo-git--entry-at-point) :path) "last"))
    (should (equal neo-git--current-selection '("last" staged)))
    (neo-git-navigation-command (lambda () (forward-line -1)))
    (should (equal (plist-get (neo-git--entry-at-point) :path) "second"))
    (should (equal neo-git--current-selection '("second" unstaged)))))

(ert-deftest neo-git-navigation-browser-bounds ()
  (with-temp-buffer
    (neo-git-browser-mode)
    (setq tabulated-list-format [("Item" 20 t)]
          tabulated-list-entries '(("one" ["One"]) ("two" ["Two"])))
    (tabulated-list-init-header)
    (tabulated-list-print t)
    (neo-git-navigation-command #'end-of-buffer)
    (should (equal (tabulated-list-get-id) "two"))
    (neo-git-navigation-command (lambda () (forward-line -1)))
    (should (equal (tabulated-list-get-id) "one"))))

(ert-deftest neo-git-navigation-empty ()
  (dolist (mode '(neo-git-mode neo-git-browser-mode))
    (with-temp-buffer
      (funcall mode)
      (let ((inhibit-read-only t)) (insert "Empty\n"))
      (neo-git-navigation-command #'beginning-of-buffer)
      (neo-git-navigation-command #'end-of-buffer)
      (should (= (point) (point-max))))))

(ert-deftest neo-git-navigation-evil-scroll ()
  (skip-unless (featurep 'evil))
  (dolist (browser '(nil t))
    (save-window-excursion
      (with-temp-buffer
        (switch-to-buffer (current-buffer))
        (if browser
            (progn
              (neo-git-browser-mode)
              (setq tabulated-list-format [("Item" 20 t)]
                    tabulated-list-entries
                    (cl-loop for i below 3
                             collect (list i (vector (format "Item %d" i)))))
              (tabulated-list-init-header)
              (tabulated-list-print t))
          (neo-git-mode)
          (setq neo-git-entries
                (cl-loop for i below 3
                         collect (list :path (format "file-%d" i) :kind 'unstaged)))
          (neo-git--render))
        (evil-local-mode 1)
        (evil-normal-state)
        ;; Binding the option with `let' does not update Evil's keymap.
        (evil-local-set-key 'normal (kbd "C-u") #'evil-scroll-up)
        (should (eq (key-binding (kbd "C-u")) #'evil-scroll-up))
        (should (eq (key-binding (kbd "C-d")) #'evil-scroll-down))
        (dolist (key '("C-d" "C-u"))
          (dotimes (_ 20)
            ;; Batch Emacs does not redisplay the window between macros.
            (set-window-start (selected-window) (point-min))
            (condition-case nil
                (execute-kbd-macro (kbd key))
              ((beginning-of-buffer end-of-buffer) nil))
            (should (if browser (tabulated-list-get-id)
                      (neo-git--entry-at-point)))
            (unless browser
              (should (equal (neo-git--selected-id) neo-git--current-selection))))
          (should (if browser (= (tabulated-list-get-id) (if (equal key "C-d") 2 0))
                    (equal (plist-get (neo-git--entry-at-point) :path)
                           (if (equal key "C-d") "file-2" "file-0")))))
        (should (if browser (= (tabulated-list-get-id) 0)
                  (equal (plist-get (neo-git--entry-at-point) :path) "file-0")))))))

(ert-run-tests-batch-and-exit)
