;;; ob-racket.el --- Racket language support in Emacs Org-mode  -*- lexical-binding: t; -*-

;; Copyright (C) 2018 DEADB17
;; This code is based on on previous work from:
;; - wallyqs https://github.com/wallyqs/ob-racket
;; - hasu https://github.com/hasu/emacs-ob-racket
;; - xchrishawk https://github.com/xchrishawk/ob-racket

;; Author: DEADB17
;; Version: 1.0.0
;; Created: 2018-01-07
;; Keywords: literate programming, racket
;; Homepage: https://github.com/DEADB17/ob-racket

;; This file is not part of GNU Emacs

;;; License:

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Support for evaluating racket code in org-mode
;; See https://orgmode.org/manual/Working-with-source-code.html

;; Requirements:

;; - Racket, see http://racket-lang.org/
;; - either racket-mode or geiser

;; For racket-mode, see https://github.com/greghendershott/racket-mode
;; For geiser, see http://www.nongnu.org/geiser/

;;; Code:

(require 'ob)

;; add racket to languages supported by org
(defvar org-babel-tangle-lang-exts)
(add-to-list 'org-babel-tangle-lang-exts '("racket" . "rkt"))

(defcustom org-babel-racket-hline-to "nil"
  "Replace hlines in incoming tables with this when translating to racket."
  :group 'org-babel
  :version "25.3"
  :package-version '(Org . "9.1.6")
  :type 'string)

(defcustom org-babel-racket-nil-to 'hline
  "Replace 'nil' in racket tables with this before returning."
  :group 'org-babel
  :version "25.3"
  :package-version '(Org . "9.1.6")
  :type 'symbol)

(defvar org-babel-default-header-args:racket
  '((:cmd . "racket --require-script"))
  "Default arguments when evaluating a Racket source block.
Defaulting `:cmd' to `racket --require-script'.")

(defun ob-racket--table-or-string (results)
  "Convert RESULTS into an appropriate elisp value.
If RESULTS look like a table, then convert them into an Emacs-lisp table,
otherwise return the results as a string."
  (let ((res (org-babel-script-escape results)))
    (if (listp res)
        (mapcar
         (lambda (el)
           (if (equal el 'nil)
               org-babel-racket-nil-to el))
         res)
      res)))

(defun ob-racket--vars-to-values (vars)
  "Convers VARS to a string of racket code.
VARS are wrapped as define-values."
  (list
   (concat
    "(define-values ("
    (mapconcat (lambda (var) (format "%s" (car var))) vars " ")
    ") (values"
    (mapconcat (lambda (var)
                 (let ((val (cdr var)))
                   (format (if (listp val) " '%S" " %S") val))) vars "")
    "))")))

(defun ob-racket--expand-fmt (fmt &optional params)
  "Expands a format list `FMT', and return a string.
PARAMS
Substitutes symbols according to the `params` alist.
The `fmt` argument may also be a string, in which
case it is returned as is."
  (if (stringp fmt)
      fmt
    (mapconcat
     (lambda (x)
       (cond
        ((stringp x) x)
        ((eq x 'ln) "\n")
        ((eq x 'quot) "\"")
        ((eq x 'apos) "\'")
        ((symbolp x)
         (let ((p (cdr (assq x params))))
           (unless p
             (error "Key %s not in %S" x params))
           (format "%s" p)))
        (t (error "Expected string or symbol: %S" fmt))))
     fmt "")))

(defun ob-racket--wrap-body (body lang vars prologue epilogue)
  "Wraps BODY with LANG as well as VARS, PROLOGUE and EPILOGUE if present.
If LANG is NIL, it defaults to `racket'.
VARS is only supported when LANG starts with `racket', `plai' or `lazy'.
Returns the wrapped body as a string."
  (let ((lang-line (or lang "racket"))
        (var-defs nil))
    (when (> (length vars) 0)
      (if (or (string-prefix-p "racket" lang-line)
              (string-prefix-p "plai" lang-line)
              (string= "lazy" lang-line))
          (setq var-defs (ob-racket--vars-to-values vars))
        (display-warning
         'ob-racket
         ":var is only supported when :lang starts with `racket', `plai' or `lazy'")))
    (mapconcat #'identity
               (append
		(list (format "#lang %s\n" lang-line))
		(when prologue (list (ob-racket--expand-fmt pro)))
		var-defs
		(list body)
		(when epilogue (list (ob-racket--expand-fmt epi))))
               "\n")))

(defvar org-babel-racket-sessions nil
  "A list to store active Racket sessions.")

(defun org-babel-racket-initiate-session (&optional session)
  "Initiate a Racket session named SESSION."
  (unless (string= session "none")
    (let ((session-buffer (cdr (assoc session org-babel-racket-sessions))))
      (unless session-buffer
        (save-window-excursion
          (racket-repl)  ;; This function should start the Racket REPL
          (rename-buffer (format "*racket-%s*" session))
          (setq session-buffer (current-buffer))
          (add-to-list 'org-babel-racket-sessions (cons session session-buffer))))
      session-buffer)))

(defun org-babel-racket-send-string (session-buffer body)
  "Send a string of Racket code BODY to the Racket session SESSION-BUFFER."
  (with-current-buffer session-buffer
    (goto-char (point-max))
    (insert body)
    (comint-send-input)
    (comint-wait-for-output)
    (buffer-substring-no-properties comint-last-input-start comint-last-output-end)))

(defun org-babel-execute:racket (body params)
  "Evaluate a `racket' code block.  BODY and PARAMS."
  (let* ((session (cdr (assoc :session params)))
         (result-type (cdr (assoc :result-type params)))
         (lang (alist-get :lang params))
         (vars (org-babel--get-vars params))
         (prologue (alist-get :prologue params))
         (epilogue (alist-get :epilogue params))
         (cmd (alist-get :cmd params "racket -u"))
         (ext (alist-get :file-ext params "rkt"))
         (file (alist-get :file params))
         (eval-file (alist-get :eval-file params))
         (session-buffer (org-babel-racket-initiate-session session))
         x-body
         result)

    ;; Prepare the body with language, variables, prologue, and epilogue
    (setq x-body (if (or lang vars prologue epilogue)
                     (ob-racket--wrap-body body lang vars prologue epilogue)
                   body))

    ;; Debug option
    (if (cdr (assoc :debug params))
        (message "Debug: %s" x-body))

    ;; Handle :eval-file
    (when (eq "" eval-file)
      (setq eval-file (alist-get :file
                                 (org-babel-generate-file-param
                                  (nth 4 (org-babel-get-src-block-info))
                                  (cons (cons :file-ext ext) params)))))

    ;; Execute the code block
    (if session
        ;; For session-based execution
        (setq result (org-babel-racket-send-string session-buffer x-body))
      ;; For non-session execution
      (if file
          (with-temp-file file (insert x-body))
        (let ((temp (or eval-file (org-babel-temp-file "ob-" (concat "." ext)))))
          (with-temp-file temp (insert x-body))
          (setq result (org-babel-eval (concat cmd " " temp) "")))))

    ;; Process the result
    (org-babel-reassemble-table
     (org-babel-result-cond (alist-get :result-params params)
       result
       (ob-racket--table-or-string result))
     (org-babel-pick-name (alist-get :colname-names params)
                          (alist-get :colnames params))
     (org-babel-pick-name (alist-get :rowname-names params)
                          (alist-get :rownames params)))))


(defun org-babel-prep-session:racket (session params)
  "Prepare SESSION according to PARAMS."
  (org-babel-racket-initiate-session session))

(provide 'ob-racket)

;;; ob-racket.el ends here
